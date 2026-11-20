import AppKit
import Carbon.HIToolbox
import Combine
import CoreText
import SwiftUI

// MARK: - État d'interaction (survol, glisser, swipe)

final class UIState: ObservableObject {
    @Published var pointer: CGPoint? { didSet { updateExpanded() } }
    /// Cadres des éléments (non publiés : évite de tout redessiner à chaque image d'animation).
    var frames: [HitZone: CGRect] = [:]
    /// Pilule ouverte (survol). Zone fixe avec hystérésis : pas de bascule pendant l'animation.
    @Published private(set) var expanded = false
    /// Décalage horizontal de la pilule ouverte quand elle est collée à un bord de l'écran.
    @Published private(set) var edgeShift: CGFloat = 0
    var pillScale: CGFloat = 0.25
    var canExpand = false { didSet { updateExpanded() } }
    @Published var isDragging = false
    @Published var squash = CGSize(width: 1, height: 1)
    @Published var nudge: CGFloat = 0
    @Published var skipDirection: CGFloat = 1
    @Published var shown = false
    /// Rendu de test uniquement : force l'état ouvert/fermé.
    var forceExpanded: Bool?

    weak var window: NSWindow?
    var onArtworkClick: (() -> Void)?
    var onArtworkDoubleClick: (() -> Void)?
    /// Retour visuel sur la pochette après un double-tap (copie du lien).
    @Published var linkStatus: LinkStatus?
    private var pendingArtworkClick: DispatchWorkItem?
    var onSkip: ((Int) -> Void)?
    var onMoved: (() -> Void)?

    private var dragMouseStart: NSPoint?
    private var dragOriginStart: NSPoint = .zero
    private var lastMouse: NSPoint = .zero
    private var lastTime: TimeInterval = 0
    private var scrollAccum: CGFloat = 0
    private var scrollFired = false

    /// Rectangle de la pilule dans la fenêtre (centrée : s'écarte des deux côtés, hauteur fixe).
    func pillRect(expanded: Bool) -> CGRect {
        let m = PillPanel.margin
        let windowWidth = (Design.width + Design.skipExtra) * pillScale + m * 2
        let windowHeight = Design.height * pillScale + PillPanel.marginY * 2
        let w = (Design.width + (expanded ? Design.skipExtra : 0)) * pillScale
        let h = Design.height * pillScale
        let shift = expanded ? edgeShift : 0
        return CGRect(x: (windowWidth - w) / 2 + shift, y: (windowHeight - h) / 2, width: w, height: h)
    }

    /// Près d'un bord, la pilule ouverte s'écarte du bord au lieu de sortir de l'écran.
    private func neededEdgeShift() -> CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return 0 }
        let vf = screen.visibleFrame
        let m = PillPanel.margin
        let windowWidth = (Design.width + Design.skipExtra) * pillScale + m * 2
        let w = (Design.width + Design.skipExtra) * pillScale
        let minX = window.frame.minX + (windowWidth - w) / 2, maxX = minX + w
        if minX < vf.minX + PillPanel.edgeInset { return vf.minX + PillPanel.edgeInset - minX }
        if maxX > vf.maxX - PillPanel.edgeInset { return vf.maxX - PillPanel.edgeInset - maxX }
        return 0
    }

    /// Recalcule le décalage après un déplacement, si la pilule est restée ouverte.
    func refreshEdgeShift() {
        guard expanded else { return }
        let shift = neededEdgeShift()
        if abs(shift - edgeShift) > 0.5 { withAnimation(Design.island) { edgeShift = shift } }
    }

    func updateExpanded() {
        guard !isDragging else { return }
        var open = false
        if let p = pointer, canExpand {
            open = pillRect(expanded: expanded).insetBy(dx: -3, dy: -3).contains(p)
        }
        // Une seule transaction animée : fond, boutons et bouton play bougent ensemble.
        if open != expanded {
            let shift = open ? neededEdgeShift() : 0
            withAnimation(Design.island) { expanded = open; edgeShift = shift }
        }
    }

    func isHovering(_ zone: HitZone) -> Bool {
        if zone == .pill, let p = pointer { return pillRect(expanded: expanded).contains(p) }
        guard let p = pointer, let f = frames[zone] else { return false }
        if zone == .play || zone == .artwork || zone == .prev || zone == .next {
            return hypot(p.x - f.midX, p.y - f.midY) <= f.width / 2
        }
        return f.contains(p)
    }

    // Déplacement de la fenêtre, avec étirement selon la vitesse (squash & stretch).
    func dragChanged(_ value: DragGesture.Value) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if dragMouseStart == nil {
            dragMouseStart = mouse
            dragOriginStart = window.frame.origin
            lastMouse = mouse
            lastTime = now
            return
        }
        guard let start = dragMouseStart else { return }
        let dx = mouse.x - start.x, dy = mouse.y - start.y
        if !isDragging {
            guard hypot(dx, dy) > 3 else { return }
            isDragging = true
        }
        window.setFrameOrigin(NSPoint(x: dragOriginStart.x + dx, y: dragOriginStart.y + dy))

        let dt = max(now - lastTime, 1.0 / 240)
        let vx = (mouse.x - lastMouse.x) / dt, vy = (mouse.y - lastMouse.y) / dt
        lastMouse = mouse; lastTime = now
        let sx = min(abs(vx) / 4500, 0.09), sy = min(abs(vy) / 4500, 0.09)
        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.7)) {
            squash = CGSize(width: 1 + sx - sy * 0.5, height: 1 + sy - sx * 0.5)
        }
    }

    func dragEnded(_ value: DragGesture.Value) {
        defer { dragMouseStart = nil }
        if !isDragging {
            if let f = frames[.artwork],
               hypot(value.location.x - f.midX, value.location.y - f.midY) <= f.width / 2 {
                // Double-tap : copie du lien. Simple clic : ouvre Musique (après le délai de double-clic).
                pendingArtworkClick?.cancel()
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    onArtworkDoubleClick?()
                } else {
                    let work = DispatchWorkItem { [weak self] in self?.onArtworkClick?() }
                    pendingArtworkClick = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
                }
            }
            return
        }
        isDragging = false
        updateExpanded()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.35)) { squash = CGSize(width: 1, height: 1) }
        keepOnScreen()
        onMoved?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshEdgeShift() }
    }

    /// Ramène la pilule dans l'écran si elle a été lâchée trop au bord.
    /// On se base sur la pilule fermée : elle peut aller jusque dans les coins.
    func keepOnScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var f = window.frame
        let local = pillRect(expanded: false)
        let pill = CGRect(x: f.minX + local.minX, y: f.minY + local.minY, width: local.width, height: local.height)
        let e = PillPanel.edgeInset
        var shift = CGPoint.zero
        if pill.minX < visible.minX + e { shift.x = visible.minX + e - pill.minX }
        if pill.maxX > visible.maxX - e { shift.x = visible.maxX - e - pill.maxX }
        if pill.minY < visible.minY + e { shift.y = visible.minY + e - pill.minY }
        if pill.maxY > visible.maxY - e { shift.y = visible.maxY - e - pill.maxY }
        f.origin.x += shift.x; f.origin.y += shift.y
        // La fenêtre (zones transparentes comprises) ne doit jamais recouvrir un bord où vit le Dock
        // ou la barre des menus : sinon le Dock masqué ne se déclenche plus.
        let sf = screen.frame
        if visible.minY > sf.minY, f.minY < sf.minY { shift.y += sf.minY - f.minY; f.origin.y = sf.minY }
        if visible.maxY < sf.maxY, f.maxY > sf.maxY { shift.y += sf.maxY - f.maxY; f.origin.y = sf.maxY - f.height }
        if visible.minX > sf.minX, f.minX < sf.minX { shift.x += sf.minX - f.minX; f.origin.x = sf.minX }
        if visible.maxX < sf.maxX, f.maxX > sf.maxX { shift.x += sf.maxX - f.maxX; f.origin.x = sf.maxX - f.width }
        guard shift != .zero else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            window.animator().setFrame(f, display: true)
        }
    }

    // Swipe à deux doigts sur le trackpad : morceau suivant / précédent.
    func handleScroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) {
            scrollAccum = 0
            scrollFired = false
        }
        if e.phase.contains(.began) || e.phase.contains(.changed) {
            guard abs(e.scrollingDeltaX) >= abs(e.scrollingDeltaY) || scrollAccum != 0 else { return }
            // Direction réelle des doigts, quel que soit le réglage « défilement naturel ».
            let finger = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            scrollAccum += finger
            // Le titre et l'artiste suivent les doigts, avec une résistance élastique.
            let rubber = (scrollAccum >= 0 ? 1 : -1) * min(abs(scrollAccum) * 0.35, 30)
            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.85)) { nudge = rubber }
            if !scrollFired, abs(scrollAccum) > 70 {
                scrollFired = true
                let next = scrollAccum < 0
                skipDirection = next ? 1 : -1
                onSkip?(next ? 1 : -1)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { nudge = 0 }
            }
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { nudge = 0 }
        }
    }
}

// MARK: - Fenêtre flottante

final class PillPanel: NSPanel {
    static let margin: CGFloat = 48
    /// Marge verticale plus courte : juste la place de l'ombre et de l'étirement.
    static let marginY: CGFloat = 24
    /// Distance minimale entre la pilule et les bords de l'écran.
    static let edgeInset: CGFloat = 8

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
    }

    /// La fenêtre est plus grande que la pilule (ombre, ouverture) : on gère nous-mêmes les bords,
    /// macOS ne doit pas la repousser sous la barre des menus.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PillHostingView<Content: View>: NSHostingView<Content> {
    var onPointer: ((CGPoint?) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let music = MusicController()
    private let settings = Settings()
    private let ui = UIState()
    private var panel: PillPanel!
    private var host: PillHostingView<PillRoot>!
    private var cancellables: Set<AnyCancellable> = []
    /// Affichée à la main (relance de l'app alors que Musique est fermée).
    private var forceShown = false
    /// Masquée avec le raccourci : reste cachée jusqu'au prochain raccourci (ou relance de Musique).
    private var userHidden = false
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var mouseMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFonts()
        settings.applyAppearance()

        panel = PillPanel()
        host = PillHostingView(rootView: PillRoot(music: music, settings: settings, ui: ui))
        host.sizingOptions = []
        host.onPointer = { [weak self] p in self?.ui.pointer = p }
        host.onScroll = { [weak self] e in self?.ui.handleScroll(e) }
        host.onRightClick = { [weak self] e in self?.showMenu(e) }
        panel.contentView = host

        ui.window = panel
        ShaderRenderer.shared.window = panel
        ui.pillScale = settings.scale
        music.$track.map { $0 != nil }.removeDuplicates().sink { [weak self] has in self?.ui.canExpand = has }
            .store(in: &cancellables)
        ui.onArtworkClick = { [weak self] in self?.music.openMusic() }
        ui.onArtworkDoubleClick = { [weak self] in self?.copyTrackLink() }
        ui.onSkip = { [weak self] dir in dir > 0 ? self?.music.next() : self?.music.previous() }
        ui.onMoved = { [weak self] in self?.saveCenter() }
        music.$track.removeDuplicates { $0?.id == $1?.id }.dropFirst().sink { [weak self] _ in
            // Un changement venu de Musique (pas d'un swipe) arrive par la droite.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.ui.skipDirection = 1 }
        }.store(in: &cancellables)

        layoutWindow(keepCenter: restoredCenter())
        settings.$size.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ui.pillScale = self.settings.scale
                self.layoutWindow(keepCenter: CGPoint(x: self.panel.frame.midX, y: self.panel.frame.midY))
                self.saveCenter()
            }
        }.store(in: &cancellables)

        // La pilule apparaît quand Musique est ouverte et disparaît quand on la ferme.
        music.$state.map { $0 != .notRunning }.removeDuplicates().sink { [weak self] running in
            guard let self else { return }
            if running { self.forceShown = false; self.userHidden = false }
            self.setVisible(!self.userHidden && (running || self.forceShown))
        }.store(in: &cancellables)

        music.start()

        // La fenêtre est plus grande que la pilule : ses zones transparentes laissent passer la souris
        // (sinon elles bloquent le Dock masqué, les coins actifs, les fenêtres dessous…).
        panel.ignoresMouseEvents = true
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.updateMousePassthrough()
        }) { mouseMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp], handler: { [weak self] e in
            DispatchQueue.main.async { self?.updateMousePassthrough() }
            return e
        }) { mouseMonitors.append(m) }

        // ⌃⌘M : afficher / masquer la pilule depuis n'importe quelle app.
        hotKey = GlobalHotKey(character: "m", modifiers: UInt32(controlKey | cmdKey)) { [weak self] in self?.togglePill() }
        setupStatusItem()

        // Première ouverture depuis Applications : active l'ouverture au démarrage (désactivable au clic droit).
        let d = UserDefaults.standard
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !d.bool(forKey: "didEnableLoginOnce") {
            d.set(true, forKey: "didEnableLoginOnce")
            if !settings.launchAtLogin { settings.toggleLaunchAtLogin() }
        }
    }

    /// Relancer PillMusic (Spotlight, Applications) affiche la pilule même si Musique est fermée.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        forceShown = true
        userHidden = false
        setVisible(true)
        return false
    }

    private func updateMousePassthrough() {
        guard panel.isVisible, ui.shown else { panel.ignoresMouseEvents = true; return }
        if ui.isDragging { panel.ignoresMouseEvents = false; return }
        let m = NSEvent.mouseLocation, f = panel.frame
        let local = CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
        let inside = ui.pillRect(expanded: ui.expanded).insetBy(dx: -3, dy: -3).contains(local)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
            if inside { ui.pointer = local } else { ui.pointer = nil }
        }
    }

    private func togglePill() {
        if ui.shown {
            userHidden = true
            setVisible(false)
        } else {
            userHidden = false
            if music.state == .notRunning { forceShown = true }
            setVisible(true)
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            if !panel.isVisible { panel.orderFrontRegardless() }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.58)) { self.ui.shown = true }
            }
        } else {
            withAnimation(.easeIn(duration: 0.22)) { ui.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.ui.shown { self.panel.orderOut(nil) }
            }
        }
    }

    private func layoutWindow(keepCenter center: CGPoint) {
        let s = settings.size.scale
        let w = (Design.width + Design.skipExtra) * s + PillPanel.margin * 2
        let h = Design.height * s + PillPanel.marginY * 2
        panel.setFrame(NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h), display: true)
        ui.keepOnScreen()
    }

    // MARK: Copie du lien du morceau

    private var linkHide: DispatchWorkItem?

    private func copyTrackLink() {
        guard let track = music.track else { return }
        linkHide?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { ui.linkStatus = .loading }
        TrackLink.find(track: track) { [weak self] url in
            DispatchQueue.main.async {
                guard let self else { return }
                if let url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { self.ui.linkStatus = url != nil ? .copied : .failed }
                let hide = DispatchWorkItem { [weak self] in
                    withAnimation(.easeOut(duration: 0.25)) { self?.ui.linkStatus = nil }
                }
                self.linkHide = hide
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: hide)
            }
        }
    }

    private func restoredCenter() -> CGPoint {
        let d = UserDefaults.standard
        if d.object(forKey: "centerX") != nil {
            let p = CGPoint(x: d.double(forKey: "centerX"), y: d.double(forKey: "centerY"))
            if NSScreen.screens.contains(where: { $0.frame.contains(p) }) { return p }
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGPoint(x: vf.midX, y: vf.maxY - Design.height * settings.size.scale / 2 - 16)
    }

    private func saveCenter() {
        UserDefaults.standard.set(Double(panel.frame.midX), forKey: "centerX")
        UserDefaults.standard.set(Double(panel.frame.midY), forKey: "centerY")
    }

    private func registerFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    // MARK: Menu clic droit

    // MARK: Icône dans la barre des menus

    /// Clic : afficher / masquer la pilule. Clic droit (ou ⌥-clic) : le menu.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.mascotIcon()
            button.toolTip = "PillMusic — afficher / masquer (⌃⌘M)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            guard let item = statusItem else { return }
            item.menu = buildMenu()
            item.button?.performClick(nil)
            item.menu = nil // le clic gauche doit rester une action, pas un menu
        } else {
            togglePill()
        }
    }

    /// La mascotte dans la barre des menus.
    static func mascotIcon() -> NSImage {
        // Logo fourni (blanc sur fond transparent, Resources/MenuIcon.png) en image « modèle » :
        // macOS l'affiche en blanc sur une barre sombre (et en noir sur une barre claire).
        guard let src = Bundle.main.image(forResource: "MenuIcon") else {
            return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage()
        }
        let h: CGFloat = 16
        let w = h * src.size.width / max(src.size.height, 1)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        img.isTemplate = true
        return img
    }

    private func showMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: host)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("Ouvrir Musique") { [weak self] in self?.music.openMusic() })
        menu.addItem(ActionItem("Morceau suivant") { [weak self] in self?.ui.skipDirection = 1; self?.music.next() })
        menu.addItem(ActionItem("Morceau précédent") { [weak self] in self?.ui.skipDirection = -1; self?.music.previous() })
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for size in PillSize.allCases {
            let item = ActionItem(size.label) { [weak self] in self?.settings.size = size }
            item.state = settings.size == size ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Taille", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let lookMenu = NSMenu()
        for look in PillAppearance.allCases {
            let item = ActionItem(look.label) { [weak self] in self?.settings.appearance = look }
            item.state = settings.appearance == look ? .on : .off
            lookMenu.addItem(item)
        }
        let lookItem = NSMenuItem(title: "Apparence", action: nil, keyEquivalent: "")
        lookItem.submenu = lookMenu
        menu.addItem(lookItem)

        let hide = ActionItem("Masquer la pilule") { [weak self] in self?.togglePill() }
        hide.keyEquivalent = "m"
        hide.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(hide)

        let login = ActionItem("Ouvrir au démarrage") { [weak self] in self?.settings.toggleLaunchAtLogin() }
        login.state = settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quitter PillMusic") { NSApp.terminate(nil) })

        return menu
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
