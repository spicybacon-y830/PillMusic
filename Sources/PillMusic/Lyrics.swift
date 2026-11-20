import AppKit
import Combine
import SwiftUI

// MARK: - Paroles synchronisées (LRCLIB)

struct LyricLine: Equatable {
    let time: Double
    let text: String
}

/// Récupère les paroles synchronisées du morceau et suit la ligne en cours.
/// Musique ne partage pas ses paroles synchronisées : on interroge LRCLIB (base ouverte, sans compte),
/// en n'envoyant que le titre, l'artiste, l'album et la durée.
final class LyricsModel: ObservableObject {
    enum Status: Equatable { case idle, loading, none, unsynced, ready }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "lyricsEnabled")
            if enabled { load(music?.track) } else { stopTimer() }
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var lines: [LyricLine] = []
    /// Ligne en cours (-1 : avant la première ligne).
    @Published private(set) var index = -1
    /// Ligne visée par le défilement (la ligne en cours, ou celle que l'utilisateur consulte).
    @Published var scrollTarget: Int? = -1
    /// L'utilisateur fait défiler les paroles : toutes les lignes deviennent visibles.
    @Published private(set) var browsing = false
    private var browseEnd: DispatchWorkItem?

    /// Glissement à deux doigts sur les paroles : on consulte, puis retour automatique à la ligne en cours.
    func userScrolled() {
        if !browsing { browsing = true }
        browseEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.spring(duration: 0.8, bounce: 0)) {
                self.browsing = false
                self.scrollTarget = self.index
            }
        }
        browseEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Les paroles apparaissent un poil en avance : la lecture paraît plus naturelle.
    private let lead = 0.25
    private weak var music: MusicController?
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var loadedTrackID: String?
    private var cache: [String: [LyricLine]?] = [:]

    init(music: MusicController) {
        enabled = UserDefaults.standard.bool(forKey: "lyricsEnabled")
        self.music = music
        music.$track.removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] t in DispatchQueue.main.async { self?.load(t) } }
            .store(in: &cancellables)
        music.$state.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sync() } }
            .store(in: &cancellables)
        music.positionChanged
            .sink { [weak self] in DispatchQueue.main.async { self?.sync() } }
            .store(in: &cancellables)
    }

    private func load(_ track: Track?) {
        guard enabled, let track else {
            if track == nil { loadedTrackID = nil; lines = []; status = .idle; index = -1; stopTimer() }
            return
        }
        guard track.id != loadedTrackID else { sync(); return }
        loadedTrackID = track.id
        index = -1
        scrollTarget = -1
        browseEnd?.cancel()
        browsing = false
        if let cached = cache[track.id] {
            apply(cached, for: track)
            return
        }
        lines = []
        status = .loading
        stopTimer()
        Self.fetch(track) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[track.id] = result
                if self.cache.count > 60 { self.cache.removeAll() }
                guard self.loadedTrackID == track.id else { return }
                self.apply(result, for: track)
            }
        }
    }

    private func apply(_ result: [LyricLine]??, for track: Track) {
        switch result {
        case .some(.some(let l)) where !l.isEmpty:
            lines = l; status = .ready
        case .some(.some):
            lines = []; status = .unsynced
        default:
            lines = []; status = .none
        }
        sync()
    }

    /// Cale la ligne affichée sur la position de lecture, puis programme le prochain changement
    /// exactement au bon moment (aucun rafraîchissement continu).
    func sync() {
        stopTimer()
        guard enabled, status == .ready, let music else { return }
        let position = music.position(at: Date()) + lead
        let i = (lines.lastIndex { $0.time <= position }) ?? -1
        if i != index {
            withAnimation(.spring(duration: 0.7, bounce: 0.12)) {
                index = i
                if !browsing { scrollTarget = i }
            }
        }
        guard music.state == .playing, i + 1 < lines.count else { return }
        let wait = max(0.03, lines[i + 1].time - position)
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.sync() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Réseau

    /// nil : rien trouvé ; [] : paroles non synchronisées seulement ; sinon les lignes datées.
    private static func fetch(_ track: Track, completion: @escaping ([LyricLine]?) -> Void) {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "artist_name", value: track.artist),
            .init(name: "track_name", value: track.title),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        request(comps.url) { json in
            if let obj = json as? [String: Any], let parsed = parse(obj) { return completion(parsed) }
            // Repli : recherche plus souple (titre sans « feat. », durée proche).
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [
                .init(name: "track_name", value: cleanTitle(track.title)),
                .init(name: "artist_name", value: track.artist),
            ]
            request(search.url) { json in
                let results = (json as? [[String: Any]]) ?? []
                let close = results.filter {
                    guard track.duration > 0, let d = $0["duration"] as? Double else { return true }
                    return abs(d - track.duration) <= 4
                }
                let synced = close.first { ($0["syncedLyrics"] as? String)?.isEmpty == false }
                completion((synced ?? close.first).flatMap(parse))
            }
        }
    }

    private static func request(_ url: URL?, completion: @escaping (Any?) -> Void) {
        guard let url else { return completion(nil) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("PillMusic", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return completion(nil) }
            completion(try? JSONSerialization.jsonObject(with: data))
        }.resume()
    }

    private static func parse(_ obj: [String: Any]) -> [LyricLine]? {
        if (obj["instrumental"] as? Bool) == true { return nil }
        if let lrc = obj["syncedLyrics"] as? String, !lrc.isEmpty { return parseLRC(lrc) }
        if let plain = obj["plainLyrics"] as? String, !plain.isEmpty { return [] }
        return nil
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(time: min * 60 + sec, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    private static func cleanTitle(_ s: String) -> String {
        var t = s
        for sep in [" (", " [", " - "] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
        return t
    }
}

// MARK: - Vue : les paroles montent, la ligne précédente s'efface

struct LyricsView: View {
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var settings: Settings
    let below: Bool
    let shown: Bool
    @Environment(\.colorScheme) private var scheme

    private var message: String? {
        switch lyrics.status {
        case .loading: return "Recherche des paroles…"
        case .none: return "Pas de paroles pour ce morceau"
        case .unsynced: return "Paroles non synchronisées"
        case .idle, .ready: return nil
        }
    }

    var body: some View {
        let k = settings.scale / 0.25
        Group {
            if let message {
                line(message, k: k).opacity(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: below ? .topTrailing : .bottomTrailing)
            } else {
                column(k: k)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: lyrics.status)
        // Apparition indépendante de la pilule : léger glissement + fondu linéaire.
        .offset(y: shown ? 0 : (below ? -8 : 8) * k)
        .animation(.spring(duration: 0.5, bounce: 0.15), value: shown)
        .opacity(shown ? 1 : 0)
        .animation(.linear(duration: 0.3), value: shown)
        .padding(.horizontal, LyricsPanel.margin)
        .padding(below ? .bottom : .top, LyricsPanel.margin)
    }

    /// Toutes les lignes en colonne ; seule la position de la colonne bouge (toujours vers le haut),
    /// et chaque ligne fond doucement selon sa distance à la ligne en cours.
    /// Au-dessus de la pilule : ligne en cours en bas, la précédente s'efface au-dessus.
    /// En dessous (pilule en haut) : ligne en cours en haut, elle s'efface en remontant vers la pilule,
    /// la suivante arrive par le bas.
    private func column(k: CGFloat) -> some View {
        let items = [(-1, "♪")] + lyrics.lines.enumerated().map { ($0.offset, $0.element.text.isEmpty ? "♪" : $0.element.text) }
        let faint = below ? 1 : -1
        let current = lyrics.index
        return ScrollView(.vertical) {
            VStack(alignment: .trailing, spacing: 4 * k) {
                ForEach(items, id: \.0) { i, text in
                    let d = i - current
                    Group {
                        if text == "♪" { note(k: k) } else { line(text, k: k) }
                    }
                    // Pas de zoom : chaque ligne apparaît et s'efface en fondu linéaire.
                    // En consultation (glissement), toutes les lignes sont visibles.
                    .opacity(d == 0 ? 1 : (lyrics.browsing ? 0.45 : (d == faint ? 0.32 : 0)))
                    .animation(.linear(duration: 0.45), value: current)
                    .animation(.linear(duration: 0.25), value: lyrics.browsing)
                    .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: Binding(get: { lyrics.scrollTarget }, set: { lyrics.scrollTarget = $0 }),
                        anchor: below ? .top : .bottom)
        // La ligne en cours reste entièrement au-dessus de la bande de fondu.
        .contentMargins(below ? .top : .bottom, 8 * k, for: .scrollContent)
        .scrollIndicators(.never)
        .scrollClipDisabled()
        // Seule la petite marge côté pilule est adoucie : la ligne suivante y apparaît en fondu,
        // sans jamais toucher la ligne en cours.
        .mask(
            VStack(spacing: 0) {
                if below { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8 * k) }
                Color.black
                if !below { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 8 * k) }
            }
            .padding(-40 * k).padding(below ? .top : .bottom, 40 * k)
        )
    }

    /// Passage instrumental : une note centrée sur la hauteur d'une ligne.
    private func note(k: CGFloat) -> some View {
        Image(systemName: "music.note")
            .font(.system(size: 13 * k, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Color.white : Color(white: 0.12))
            .frame(height: 19 * k)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func line(_ text: String, k: CGFloat) -> some View {
        Text(text)
            .font(Design.font(15 * k))
            .foregroundStyle(scheme == .dark ? Color.white : Color(white: 0.12))
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Flou translucide du bureau derrière le panneau.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Fenêtre des paroles

final class LyricsPanel: NSPanel {
    static let margin: CGFloat = 16

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Toujours au-dessus de la pilule (et de son ombre).
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

/// État d'affichage du panneau (au-dessus / en dessous, visible).
final class LyricsPlacement: ObservableObject {
    @Published var below = false
    @Published var shown = false
}

struct LyricsRoot: View {
    @ObservedObject var lyrics: LyricsModel
    @ObservedObject var settings: Settings
    @ObservedObject var placement: LyricsPlacement

    var body: some View {
        LyricsView(lyrics: lyrics, settings: settings, below: placement.below, shown: placement.shown)
    }
}
