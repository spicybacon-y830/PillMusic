import AppKit
import SwiftUI

// MARK: - Design (valeurs exactes du fichier Paper, en unités de design)

enum Design {
    static let width: CGFloat = 777
    static let paddingH: CGFloat = 24
    static let paddingV: CGFloat = 24
    static let disc: CGFloat = 160
    static let gap: CGFloat = 16
    static var height: CGFloat { disc + paddingV * 2 }
    /// Boutons précédent / suivant révélés au survol.
    static let skip: CGFloat = 84
    static var skipExtra: CGFloat { (skip + gap) * 2 }
    /// Ressort de l'ouverture au survol (appliqué à toute la pilule d'un coup, fond compris).
    static let island = Animation.spring(response: 0.5, dampingFraction: 0.5)
    static var infoWidth: CGFloat { width - paddingH * 2 - disc * 2 - gap * 2 }

    static func colors(_ scheme: ColorScheme) -> (bg: Color, title: Color, secondary: Color, track: Color, fill: Color) {
        scheme == .dark
            ? (Color(hex: 0x1A1A1A), Color(hex: 0xFFFFFF), Color(hex: 0xB4B4B4), Color(hex: 0x3F3F3F), Color(hex: 0x979797))
            : (Color(hex: 0xFFFFFF), Color(hex: 0x5C5C5C), Color(hex: 0x8C8C8C), Color(hex: 0xE5E5E5), Color(hex: 0x979797))
    }

    static func font(_ size: CGFloat) -> Font {
        NSFont(name: "Geist-Medium", size: size) != nil
            ? .custom("Geist-Medium", fixedSize: size)
            : .system(size: size, weight: .medium)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum HitZone: Hashable { case pill, artwork, play, bar, prev, next }

struct FramesKey: PreferenceKey {
    static var defaultValue: [HitZone: CGRect] = [:]
    static func reduce(value: inout [HitZone: CGRect], nextValue: () -> [HitZone: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    func hitZone(_ zone: HitZone) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: FramesKey.self, value: [zone: g.frame(in: .named("root"))])
        })
    }
}

// MARK: - Pilule

struct PillRoot: View {
    @ObservedObject var music: MusicController
    @ObservedObject var settings: Settings
    @ObservedObject var ui: UIState
    @Environment(\.colorScheme) private var scheme

    private var S: CGFloat { settings.scale }

    var body: some View {
        let c = Design.colors(scheme)
        // Au survol, la pilule s'étire vers la droite (même hauteur, pochette immobile)
        // et révèle précédent / suivant, à la façon de la Dynamic Island.
        let expanded = ui.forceExpanded ?? ui.expanded
        let skip = Design.skip * S

        HStack(spacing: 0) {
            ArtworkDisc(image: music.artwork, trackID: music.track?.id, direction: ui.skipDirection,
                        size: Design.disc * S, hovering: ui.isHovering(.artwork), linkStatus: ui.linkStatus)
                .hitZone(.artwork)
                .padding(.trailing, Design.gap * S)

            InfoColumn(music: music, ui: ui, S: S, colors: c)
                .frame(width: Design.infoWidth * S)

            // Chaque bouton grandit au même rythme que la place qui s'ouvre : ni débordement, ni découpe.
            SkipButton(forward: false, size: skip, colors: c, hovering: ui.isHovering(.prev), visible: expanded) {
                ui.skipDirection = -1; music.previous()
            }
            .hitZone(.prev)
            .frame(width: expanded ? skip : 0)
            .padding(.leading, expanded ? Design.gap * S : 0)

            SkipButton(forward: true, size: skip, colors: c, hovering: ui.isHovering(.next), visible: expanded) {
                ui.skipDirection = 1; music.next()
            }
            .hitZone(.next)
            .frame(width: expanded ? skip : 0)
            .padding(.leading, expanded ? Design.gap * S : 0)

            PlayButton(music: music, ui: ui, size: Design.disc * S)
                .padding(.leading, Design.gap * S)
        }
        .padding(.horizontal, Design.paddingH * S)
        .padding(.vertical, Design.paddingV * S)
        .frame(height: Design.height * S)
        .background(
            Capsule().fill(c.bg)
                .overlay(Capsule().strokeBorder(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05), lineWidth: 0.5))
        )
        .clipShape(Capsule())
        .hitZone(.pill)
        // Effets « bubbly » : survol, lévitation pendant le déplacement, squash & stretch.
        .scaleEffect(x: ui.squash.width, y: ui.squash.height)
        .scaleEffect(ui.isDragging ? 1.045 : 1)
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : (ui.isDragging ? 0.22 : 0.13)),
                radius: (ui.isDragging ? 26 : 14) * S * 2, y: (ui.isDragging ? 14 : 6) * S * 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: ui.isDragging)
        // Apparition / disparition avec Musique
        .scaleEffect(ui.shown ? 1 : 0.55)
        .blur(radius: ui.shown ? 0 : 6)
        .opacity(ui.shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "root")
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("root"))
                .onChanged { ui.dragChanged($0) }
                .onEnded { ui.dragEnded($0) }
        )
        .onPreferenceChange(FramesKey.self) { ui.frames = $0 }
    }
}

// MARK: - Pochette

struct ArtworkDisc: View {
    let image: NSImage?
    let trackID: String?
    let direction: CGFloat
    let size: CGFloat
    let hovering: Bool
    var linkStatus: LinkStatus? = nil

    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [Color(hex: 0xD9D9DE), Color(hex: 0x9C9CA6)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .id(image.map { ObjectIdentifier($0) })
            .transition(.asymmetric(
                insertion: .scale(scale: 0.6).combined(with: .opacity)
                    .combined(with: .offset(x: direction * size * 0.2)),
                removal: .opacity.animation(.easeOut(duration: 0.2).delay(0.3))
            ))

            // Retour du double-tap : lien en recherche, copié, ou introuvable.
            if let linkStatus {
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                    Image(systemName: linkStatus.symbol)
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white)
                        .id(linkStatus)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                .frame(width: size, height: size)
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.6), value: image.map { ObjectIdentifier($0) })
        .animation(.easeInOut(duration: 0.3), value: image == nil)
    }
}

// MARK: - Titre, artiste, progression

struct InfoColumn: View {
    @ObservedObject var music: MusicController
    @ObservedObject var ui: UIState
    let S: CGFloat
    let colors: (bg: Color, title: Color, secondary: Color, track: Color, fill: Color)

    private var texts: (String, String) {
        switch music.state {
        case .permissionDenied: return ("Accès à Musique refusé", "Réglages › Confidentialité › Automatisation")
        case .notRunning: return ("Musique est fermée", "Clique sur play pour lancer")
        case .stopped: return ("Rien en lecture", "Lance un morceau dans Musique")
        default: return (music.track?.title ?? "—", music.track?.artist ?? "")
        }
    }

    var body: some View {
        let (title, artist) = texts
        VStack(alignment: .leading, spacing: 27 * S * 0.6) {
            VStack(alignment: .leading, spacing: 4 * S) {
                Marquee(text: title, font: Design.font(max(40 * S, 12)), color: colors.title, lineHeight: max(48 * S, 14))
                Marquee(text: artist, font: Design.font(max(20 * S, 9)), color: colors.secondary, lineHeight: max(24 * S, 11))
            }
            .id(music.track?.id ?? title)
            .transition(.asymmetric(
                insertion: .modifier(active: SlideBlur(x: ui.skipDirection * 40 * S, blur: 6, opacity: 0),
                                     identity: SlideBlur(x: 0, blur: 0, opacity: 1)),
                removal: .modifier(active: SlideBlur(x: -ui.skipDirection * 40 * S, blur: 6, opacity: 0),
                                   identity: SlideBlur(x: 0, blur: 0, opacity: 1))
            ))
            // Swipe : seuls le titre et l'artiste glissent (gauche = suivant, droite = précédent).
            .offset(x: ui.nudge)
            .opacity(1 - Double(min(abs(ui.nudge) / 60, 0.5)))

            ProgressRow(music: music, ui: ui, S: S, colors: colors)
        }
        .padding(.horizontal, 32 * S)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: music.track?.id)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: music.state)
    }
}

struct SlideBlur: ViewModifier {
    let x: CGFloat
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.offset(x: x).blur(radius: blur).opacity(opacity)
    }
}

struct ProgressRow: View {
    @ObservedObject var music: MusicController
    @ObservedObject var ui: UIState
    let S: CGFloat
    let colors: (bg: Color, title: Color, secondary: Color, track: Color, fill: Color)

    private let _scrubBox = State<Double?>(initialValue: nil)
    private var scrub: Double? { get { _scrubBox.wrappedValue } nonmutating set { _scrubBox.wrappedValue = newValue } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: music.state == .playing ? 0.25 : 60)) { ctx in
            let duration = music.track?.duration ?? 0
            let position = scrub.map { $0 * duration } ?? music.position(at: ctx.date)
            let fraction = duration > 0 ? position / duration : 0
            let active = ui.isHovering(.bar) || scrub != nil
            let barH = max(7 * S, 2.5) * (active ? 2 : 1)
            let timeFont = Design.font(max(16 * S, 8))

            HStack(spacing: 8 * S) {
                Text(format(position))
                    .font(timeFont).monospacedDigit()
                    .foregroundStyle(colors.secondary)
                    .fixedSize()

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(colors.track)
                        Rectangle().fill(colors.fill)
                            .frame(width: max(0, g.size.width * fraction))
                            .animation(scrub == nil ? .linear(duration: 0.25) : nil, value: fraction)
                    }
                    .frame(height: barH)
                    .clipShape(Capsule())
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard duration > 0 else { return }
                                scrub = min(max(v.location.x / g.size.width, 0), 1)
                            }
                            .onEnded { _ in
                                if let s = scrub { music.seek(to: s * duration) }
                                scrub = nil
                            }
                    )
                }
                .frame(height: max(7 * S, 2.5) * 2 + 2)
                .hitZone(.bar)
                .animation(.spring(response: 0.28, dampingFraction: 0.5), value: active)

                Text("-" + format(max(duration - position, 0)))
                    .font(timeFont).monospacedDigit()
                    .foregroundStyle(colors.secondary)
                    .fixedSize()
            }
            .opacity(music.track == nil ? 0.45 : 1)
        }
    }

    private func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Texte défilant pour les titres longs

struct Marquee: View {
    let text: String
    let font: Font
    let color: Color
    let lineHeight: CGFloat

    private let _textWidthBox = State<CGFloat>(initialValue: 0)
    private var textWidth: CGFloat { get { _textWidthBox.wrappedValue } nonmutating set { _textWidthBox.wrappedValue = newValue } }
    private let _startBox = State<Date>(initialValue: Date())
    private var start: Date { get { _startBox.wrappedValue } nonmutating set { _startBox.wrappedValue = newValue } }

    var body: some View {
        GeometryReader { g in
            let overflow = textWidth > g.size.width + 0.5
            Group {
                if overflow {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { ctx in
                        let gap: CGFloat = 36
                        let speed: CGFloat = 26
                        let delay = 2.2
                        let cycle = delay + Double((textWidth + gap) / speed)
                        let phase = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                        let offset = phase < delay ? 0 : -CGFloat(phase - delay) * speed
                        HStack(spacing: gap) { label; label }
                            .offset(x: offset)
                    }
                    .frame(width: g.size.width, alignment: .leading)
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                            .init(color: .black, location: 0.9), .init(color: .clear, location: 1),
                        ], startPoint: .leading, endPoint: .trailing)
                    )
                } else {
                    label.frame(width: g.size.width, alignment: .leading)
                }
            }
            .frame(height: lineHeight)
        }
        .frame(height: lineHeight)
        .background(
            label.hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
        )
        .onChange(of: text) { start = Date() }
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

// MARK: - Bouton play/pause en métal liquide

struct PlayButton: View {
    @ObservedObject var music: MusicController
    @ObservedObject var ui: UIState
    let size: CGFloat

    private let _pressedBox = State<Bool>(initialValue: false)
    private var pressed: Bool { get { _pressedBox.wrappedValue } nonmutating set { _pressedBox.wrappedValue = newValue } }
    private let _boostTokenBox = State<Int>(initialValue: 0)
    private var boostToken: Int { get { _boostTokenBox.wrappedValue } nonmutating set { _boostTokenBox.wrappedValue = newValue } }
    private let _wobbleBox = State<Bool>(initialValue: false)
    private var wobble: Bool { get { _wobbleBox.wrappedValue } nonmutating set { _wobbleBox.wrappedValue = newValue } }

    var body: some View {
        let playing = music.state == .playing
        let hovering = ui.isHovering(.play)

        ZStack {
            Circle().fill(Color(nsColor: music.discColor))
                .animation(.easeInOut(duration: 0.6), value: music.discColor)
            LiquidMetal(renderer: .shared,
                        palette: music.palette,
                        speed: playing ? (hovering ? 1.6 : 1) : 0,
                        boostToken: boostToken,
                        size: size)
                .clipShape(Circle())

            Group {
                if playing { PauseGlyph().fill(.white) } else { PlayGlyph().fill(.white) }
            }
            .frame(width: size * 78 / 160, height: size * 78 / 160)
            .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.01)
            .transaction { $0.animation = nil }
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed ? 0.84 : (hovering ? 1.07 : 1))
        .scaleEffect(x: wobble ? 1.08 : 1, y: wobble ? 0.93 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: pressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.3), value: wobble)
        .contentShape(Circle())
        .hitZone(.play)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { v in
                    pressed = false
                    let inside = hypot(v.location.x - size / 2, v.location.y - size / 2) <= size / 2 + 6
                    guard inside else { return }
                    if music.state != .playing { boostToken += 1 } // élan seulement au lancement
                    wobble = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { wobble = false }
                    music.playPause()
                }
        )
    }
}

/// Triangle arrondi du design (SVG viewBox -27 -27 78 78), ramené en 0…78.
struct PlayGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 78
        let a = CGPoint(x: 16.54 * k, y: 4.93 * k)
        let b = CGPoint(x: 74.2 * k, y: 39 * k)
        let c = CGPoint(x: 16.54 * k, y: 73.07 * k)
        let r = 6.6 * k
        var p = Path()
        p.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        p.addArc(tangent1End: a, tangent2End: b, radius: r)
        p.addArc(tangent1End: b, tangent2End: c, radius: r)
        p.addArc(tangent1End: c, tangent2End: a, radius: r)
        p.closeSubpath()
        return p
    }
}

struct PauseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 78
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 16.25 * k, y: 9.75 * k, width: 16.25 * k, height: 58.5 * k), cornerSize: CGSize(width: k, height: k))
        p.addRoundedRect(in: CGRect(x: 45.5 * k, y: 9.75 * k, width: 16.25 * k, height: 58.5 * k), cornerSize: CGSize(width: k, height: k))
        return p
    }
}

// MARK: - Boutons précédent / suivant

struct SkipButton: View {
    let forward: Bool
    let size: CGFloat
    let colors: (bg: Color, title: Color, secondary: Color, track: Color, fill: Color)
    let hovering: Bool
    let visible: Bool
    let action: () -> Void

    private let _pressedBox = State<Bool>(initialValue: false)
    private var pressed: Bool { get { _pressedBox.wrappedValue } nonmutating set { _pressedBox.wrappedValue = newValue } }

    var body: some View {
        ZStack {
            Circle().fill(colors.track)
            Circle().fill(colors.title.opacity(hovering ? 0.12 : 0))
            Image(systemName: forward ? "forward.fill" : "backward.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(colors.title)
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed ? 0.9 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
        // Grandit exactement avec la place qui s'ouvre : même ressort que la pilule, sans délai
        // (l'animation vient du conteneur, une seule transaction pour tout).
        .scaleEffect(visible ? 1 : 0.01)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { v in
                    pressed = false
                    guard hypot(v.location.x - size / 2, v.location.y - size / 2) <= size / 2 + 4 else { return }
                    action()
                }
        )
    }
}
