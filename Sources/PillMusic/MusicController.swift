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

/// Pilote l'app Musique via AppleScript (API officielle et stable de macOS).
final class MusicController: ObservableObject {
    static let bundleID = "com.apple.Music"
    static let defaultTint = NSColor(srgbRed: 0xCA / 255, green: 0x05 / 255, blue: 0x03 / 255, alpha: 1)
    static let defaultDisc = NSColor(srgbRed: 0xC1 / 255, green: 0x1F / 255, blue: 0x42 / 255, alpha: 1)

    @Published private(set) var state: PlayerState = .notRunning
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tints: [NSColor] = [MusicController.defaultTint]
    @Published private(set) var discColor: NSColor = MusicController.defaultDisc

    private var positionBase: Double = 0
    /// État choisi au clic : on l'affiche tant que Musique ne l'a pas confirmé (évite le clignotement).
    private var pendingState: PlayerState?
    /// Début d'un « stop » : entre deux morceaux, Musique s'arrête brièvement. On garde l'affichage.
    private var stoppedSince: Date?
    private var pendingUntil = Date.distantPast
    private var positionDate = Date()

    private let queue = DispatchQueue(label: "pillmusic.applescript", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:] // utilisé uniquement sur `queue`
    private var timer: Timer?
    private var refreshInFlight = false
    private var artworkTrackID: String?
    private var artworkCache: [String: (NSImage?, Palette.Colors)] = [:]

    // MARK: - Cycle de vie

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfoChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil
        )
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.3
        refresh()
    }

    @objc private func playerInfoChanged() { refresh() }

    @objc private func appsChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Position actuelle, interpolée entre deux lectures pour une barre fluide.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let p = state == .playing ? positionBase + date.timeIntervalSince(positionDate) : positionBase
        return min(max(p, 0), max(track.duration, 0))
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
        run("tell application \"Music\" to playpause") { _ in self.refreshSoon() }
    }

    func next() {
        guard isMusicRunning else { return }
        run("tell application \"Music\" to next track") { _ in self.refreshSoon() }
    }

    func previous() {
        guard isMusicRunning else { return }
        run("tell application \"Music\" to previous track") { _ in self.refreshSoon() }
    }

    func seek(to seconds: Double) {
        guard isMusicRunning, track != nil else { return }
        positionBase = seconds; positionDate = Date()
        objectWillChange.send()
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        run("tell application \"Music\" to set player position to \(value)") { _ in self.refreshSoon() }
    }

    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func launchMusicAndPlay() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            self.queue.asyncAfter(deadline: .now() + 1.2) {
                _ = self.execute("tell application \"Music\" to play")
                DispatchQueue.main.async { self.refreshSoon() }
            }
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refresh() }
    }

    // MARK: - Lecture de l'état

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
        run(Self.stateScript) { result in
            self.refreshInFlight = false
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

    private func loadArtwork(for track: Track) {
        artworkTrackID = track.id
        if let cached = artworkCache[track.id] {
            setArtwork(cached.0, colors: cached.1, for: track.id)
            return
        }
        queue.async {
            var image: NSImage?
            if case .success(let d) = self.execute("tell application \"Music\" to get raw data of artwork 1 of current track") {
                let data = d.data
                if !data.isEmpty { image = NSImage(data: data) }
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
        DispatchQueue.main.async {
            self.artworkCache[track.id] = (image, colors)
            if self.artworkCache.count > 40 { self.artworkCache.removeAll() }
            guard self.track?.id == track.id else { return }
            self.setArtwork(image, colors: colors, for: track.id)
        }
    }

    private func setArtwork(_ image: NSImage?, colors: Palette.Colors, for id: String?) {
        if id == nil { artworkTrackID = nil }
        artwork = image
        tints = colors.tints
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
