import AppKit
import Combine

enum PlayerState: Equatable {
    case notRunning, stopped, playing, paused, permissionDenied
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

/// Lecteur piloté : l'app Musique d'Apple ou Spotify (tous deux scriptables en AppleScript).
enum Player: String, CaseIterable {
    case music, spotify

    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    var appName: String { self == .music ? "Music" : "Spotify" }
    var label: String { self == .music ? "Musique" : "Spotify" }
    var notification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
}

/// Pilote Musique ou Spotify via AppleScript (API officielle et stable de macOS).
/// Le lecteur actif suit celui qui joue : lancer un morceau dans l'un ou l'autre suffit.
final class MusicController: ObservableObject {
    static let defaultTint = NSColor(srgbRed: 0xCA / 255, green: 0x05 / 255, blue: 0x03 / 255, alpha: 1)
    static let defaultDisc = NSColor(srgbRed: 0xC1 / 255, green: 0x1F / 255, blue: 0x42 / 255, alpha: 1)

    @Published private(set) var state: PlayerState = .notRunning
    /// Lecteur actif (mémorisé : c'est lui que le bouton play lance quand tout est fermé).
    @Published private(set) var player: Player = Player(rawValue: UserDefaults.standard.string(forKey: "player") ?? "") ?? .music {
        didSet { UserDefaults.standard.set(player.rawValue, forKey: "player") }
    }
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: Palette.Colors = .fallback
    @Published private(set) var discColor: NSColor = MusicController.defaultDisc

    private var positionBase: Double = 0
    /// État choisi au clic : on l'affiche tant que Musique ne l'a pas confirmé (évite le clignotement).
    private var pendingState: PlayerState?
    /// Début d'un « stop » : entre deux morceaux, Musique s'arrête brièvement. On garde l'affichage.
    private var stoppedSince: Date?
    private var pendingUntil = Date.distantPast
    private var positionDate = Date() { didSet { positionChanged.send() } }
    /// Émis quand la position de lecture est recalée (seek, pause, dérive) : les paroles se resynchronisent.
    let positionChanged = PassthroughSubject<Void, Never>()

    private let queue = DispatchQueue(label: "pillmusic.applescript", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:] // utilisé uniquement sur `queue`
    private var timer: Timer?
    private var refreshInFlight = false
    private var artworkTrackID: String?
    private var artworkCache: [String: (NSImage?, Palette.Colors)] = [:]
    /// Spotify donne l'adresse de la pochette avec l'état du morceau.
    private var artworkURLs: [String: URL] = [:]

    // MARK: - Cycle de vie

    func start() {
        for p in Player.allCases {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(playerInfoChanged(_:)), name: NSNotification.Name(p.notification), object: nil
            )
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        scheduleTimer()
        refresh()
        // La cadence d'interrogation dépend de la lecture et de l'alimentation.
        stateSink = $state.removeDuplicates().combineLatest(PowerMonitor.shared.$onBattery, PowerMonitor.shared.$lowPower)
            .dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleTimer() } }
    }

    private var stateSink: AnyCancellable?

    /// Musique prévient déjà de chaque changement (notification) : l'interrogation ne sert qu'à recaler
    /// la position, la position est extrapolée localement entre deux. En pause ou fermée, on espace beaucoup.
    private func scheduleTimer() {
        let saving = PowerMonitor.shared.saving
        let interval: TimeInterval
        switch state {
        case .playing: interval = saving ? 4 : 2
        case .notRunning: interval = 10
        default: interval = saving ? 10 : 5
        }
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = interval * 0.25
    }

    @objc private func playerInfoChanged(_ note: Notification) {
        // Le lecteur qui se met à jouer devient le lecteur actif.
        if let source = Player.allCases.first(where: { $0.notification == note.name.rawValue }), source != player,
           (note.userInfo?["Player State"] as? String) == "Playing" {
            switchTo(source)
        }
        refresh()
    }

    @objc private func appsChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Player.allCases.contains(where: { $0.bundleID == app.bundleIdentifier }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    var isMusicRunning: Bool { player.isRunning }

    /// Choix manuel du lecteur (menu) : utile quand les deux sont ouverts.
    func choose(_ p: Player) {
        guard p != player else { return }
        switchTo(p)
        refresh()
    }

    private func switchTo(_ p: Player) {
        player = p
        pendingState = nil
        stoppedSince = nil
        track = nil
        setArtwork(nil, colors: .fallback, for: nil)
    }

    /// Position actuelle, interpolée entre deux lectures pour une barre fluide.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let p = state == .playing ? positionBase + date.timeIntervalSince(positionDate) : positionBase
        return min(max(p, 0), max(track.duration, 0))
    }

    /// Rendu de test uniquement : morceau fictif.
    func loadDemo(artwork: NSImage?) {
        track = Track(id: "demo", title: "Ain't in LA", artist: "ADÉLA", album: "", duration: 173)
        state = .paused
        positionBase = 128
        self.artwork = artwork
    }

    // MARK: - Actions

    func playPause() {
        if !isMusicRunning {
            launchMusicAndPlay()
            return
        }
        // Réponse visuelle immédiate, confirmée ensuite par Musique.
        if state == .playing {
            positionBase = position(at: Date()); positionDate = Date()
            state = .paused
        } else if state == .paused {
            positionDate = Date()
            state = .playing
        }
        pendingState = state
        pendingUntil = Date().addingTimeInterval(2)
        run("tell application \"\(player.appName)\" to playpause") { _ in self.refreshSoon() }
    }

    func next() {
        guard isMusicRunning else { return }
        run("tell application \"\(player.appName)\" to next track") { _ in self.refreshSoon() }
    }

    func previous() {
        guard isMusicRunning else { return }
        run("tell application \"\(player.appName)\" to previous track") { _ in self.refreshSoon() }
    }

    func seek(to seconds: Double) {
        guard isMusicRunning, track != nil else { return }
        positionBase = seconds; positionDate = Date()
        objectWillChange.send()
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        run("tell application \"\(player.appName)\" to set player position to \(value)") { _ in self.refreshSoon() }
    }

    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func launchMusicAndPlay() {
        let p = player
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            self.queue.asyncAfter(deadline: .now() + 1.2) {
                _ = self.execute("tell application \"\(p.appName)\" to play")
                DispatchQueue.main.async { self.refreshSoon() }
            }
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refresh() }
    }

    // MARK: - Lecture de l'état

    private static let spotifyStateScript = """
    tell application "Spotify"
        set ps to player state as text
        if ps is "stopped" then return {"stopped"}
        try
            set t to current track
            return {ps, name of t, artist of t, album of t, (duration of t) / 1000, player position, id of t, artwork url of t}
        on error
            return {ps}
        end try
    end tell
    """

    private static let stateScript = """
    tell application "Music"
        set ps to player state as text
        if ps is "stopped" then return {"stopped"}
        try
            set t to current track
            set tid to ""
            try
                set tid to persistent ID of t
            end try
            return {ps, name of t, artist of t, album of t, duration of t, player position, tid}
        on error
            return {ps}
        end try
    end tell
    """

    func refresh() {
        // Lecteur actif fermé mais l'autre ouvert : on bascule dessus.
        if !player.isRunning, let other = Player.allCases.first(where: { $0 != player && $0.isRunning }) {
            switchTo(other)
        }
        guard isMusicRunning else {
            if state != .notRunning || track != nil {
                state = .notRunning
                track = nil
                setArtwork(nil, colors: .fallback, for: nil)
            }
            return
        }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let p = player
        run(p == .music ? Self.stateScript : Self.spotifyStateScript) { result in
            self.refreshInFlight = false
            guard p == self.player else { return self.refreshSoon() } // lecteur changé entre-temps
            self.apply(result)
        }
    }

    private func apply(_ result: Result<NSAppleEventDescriptor, ScriptError>) {
        let desc: NSAppleEventDescriptor
        switch result {
        case .failure(.permissionDenied):
            state = .permissionDenied
            return
        case .failure:
            return // Musique est peut-être en train de se lancer ou de se fermer : on réessaie au prochain tick.
        case .success(let d):
            desc = d
        }

        let ps = desc.atIndex(1)?.stringValue ?? "stopped"
        var newState: PlayerState
        switch ps {
        case "playing", "fast forwarding", "rewinding": newState = .playing
        case "paused": newState = .paused
        default: newState = .stopped
        }
        if let pending = pendingState {
            if newState == pending || Date() > pendingUntil {
                pendingState = nil
            } else if newState == .playing || newState == .paused {
                newState = pending // réponse encore périmée de Musique : on garde l'état choisi
            }
        }

        if newState == .stopped {
            // Ne vide la pilule que si l'arrêt dure vraiment (pas le blanc entre deux titres).
            let since = stoppedSince ?? Date()
            stoppedSince = since
            if track != nil, Date().timeIntervalSince(since) < 4 { return }
            state = .stopped
            track = nil
            setArtwork(nil, colors: .fallback, for: nil)
            return
        }
        stoppedSince = nil

        // Morceau en cours de chargement (infos pas encore prêtes) : on garde l'affichage actuel.
        let incomingTitle = desc.numberOfItems >= 7 ? (desc.atIndex(2)?.stringValue ?? "") : ""
        guard !incomingTitle.isEmpty else {
            if track != nil || newState != state { state = newState }
            return
        }

        let title = desc.atIndex(2)?.stringValue ?? ""
        let artist = desc.atIndex(3)?.stringValue ?? ""
        let album = desc.atIndex(4)?.stringValue ?? ""
        let duration = desc.atIndex(5)?.doubleValue ?? 0
        let position = desc.atIndex(6)?.doubleValue ?? 0
        var id = desc.atIndex(7)?.stringValue ?? ""
        if id.isEmpty { id = "\(title)|\(artist)|\(album)" }
        if let art = desc.atIndex(8)?.stringValue, let url = URL(string: art) { artworkURLs[id] = url }

        let newTrack = Track(id: id, title: title, artist: artist, album: album, duration: duration)
        let trackChanged = newTrack.id != track?.id

        // Ne recale la position que si elle a vraiment dérivé, pour éviter les sauts.
        let predicted = self.position(at: Date())
        if trackChanged || newState != state || abs(predicted - position) > 0.75 {
            positionBase = position
            positionDate = Date()
        }
        if newTrack != track { track = newTrack }
        if newState != state { state = newState }
        if trackChanged || artworkTrackID != newTrack.id { loadArtwork(for: newTrack) }
    }

    // MARK: - Pochette

    /// Identifiant et image demandés ensemble : impossible de mélanger deux morceaux.
    private static let artworkScript = """
    tell application "Music"
        set t to current track
        set pid to ""
        try
            set pid to persistent ID of t
        end try
        try
            return {pid, raw data of artwork 1 of t}
        on error
            return {pid}
        end try
    end tell
    """

    private func loadArtwork(for track: Track) {
        artworkTrackID = track.id
        if let cached = artworkCache[track.id] {
            setArtwork(cached.0, colors: cached.1, for: track.id)
            return
        }
        if player == .spotify {
            let fetch: (URL) -> Void = { url in
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    let image = data.flatMap { NSImage(data: $0) }
                    if let image { self.queue.async { self.finishArtwork(image, for: track) } }
                    else { ArtworkSearch.find(track: track) { found in self.queue.async { self.finishArtwork(found, for: track) } } }
                }.resume()
            }
            if let url = artworkURLs[track.id] { fetch(url) }
            else { ArtworkSearch.find(track: track) { found in self.queue.async { self.finishArtwork(found, for: track) } } }
            return
        }
        queue.async {
            var image: NSImage?
            if case .success(let d) = self.execute(Self.artworkScript) {
                // Le morceau a pu changer pendant la demande : on ne garde la pochette que si c'est le bon.
                let pid = d.atIndex(1)?.stringValue ?? ""
                if !pid.isEmpty, !track.id.contains("|"), pid != track.id {
                    DispatchQueue.main.async {
                        if self.artworkTrackID == track.id { self.artworkTrackID = nil }
                        self.refreshSoon()
                    }
                    return
                }
                if let data = d.atIndex(2)?.data, !data.isEmpty { image = NSImage(data: data) }
            }
            if let image {
                self.finishArtwork(image, for: track)
            } else {
                ArtworkSearch.find(track: track) { found in
                    self.queue.async { self.finishArtwork(found, for: track) }
                }
            }
        }
    }

    private func finishArtwork(_ image: NSImage?, for track: Track) {
        let colors = image.flatMap { Palette.extract(from: $0) } ?? .fallback
        Self.writeDiagnostic(image: image, colors: colors, track: track)
        DispatchQueue.main.async {
            self.artworkCache[track.id] = (image, colors)
            if self.artworkCache.count > 40 { self.artworkCache.removeAll() }
            guard self.track?.id == track.id else { return }
            self.setArtwork(image, colors: colors, for: track.id)
        }
    }

    /// Diagnostic local : dernière pochette et couleurs extraites (~/Library/Caches/PillMusic).
    private static func writeDiagnostic(image: NSImage?, colors: Palette.Colors, track: Track) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("PillMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("last-artwork.png"))
        }
        func hex(_ c: NSColor) -> String {
            let s = c.usingColorSpace(.sRGB) ?? c
            return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
        }
        let text = "\(track.title) — \(track.artist)\ntints: \(colors.tints.map(hex).joined(separator: " "))\ndisc: \(hex(colors.disc))\n"
        try? text.write(to: dir.appendingPathComponent("last-palette.txt"), atomically: true, encoding: .utf8)
    }

    private func setArtwork(_ image: NSImage?, colors: Palette.Colors, for id: String?) {
        if id == nil { artworkTrackID = nil }
        artwork = image
        palette = colors
        discColor = colors.disc
    }

    // MARK: - AppleScript

    enum ScriptError: Error { case permissionDenied, failed(Int) }

    private func run(_ source: String, completion: @escaping (Result<NSAppleEventDescriptor, ScriptError>) -> Void) {
        queue.async {
            let result = self.execute(source)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// À appeler uniquement depuis `queue`.
    private func execute(_ source: String) -> Result<NSAppleEventDescriptor, ScriptError> {
        let script: NSAppleScript
        if let s = scripts[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return .failure(.failed(-1)) }
            var compileError: NSDictionary?
            s.compileAndReturnError(&compileError)
            scripts[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
            return .failure(code == -1743 ? .permissionDenied : .failed(code))
        }
        return .success(result)
    }
}
