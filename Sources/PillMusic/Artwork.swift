import AppKit

/// Couleurs dérivées de la pochette pour teinter le shader du bouton.
enum Palette {
    struct Colors: Equatable {
        /// [dominante, accent 1, accent 2]
        var tints: [NSColor]
        /// Part de l'accent 1 et de l'accent 2 dans le métal (selon leur surface sur la pochette).
        var coverage: [Float]
        /// Intensité de la teinte (pochettes très blanches → métal plus argenté).
        var strength: Float
        var disc: NSColor

        static let fallback = Colors(tints: [MusicController.defaultTint], coverage: [0, 0], strength: 1,
                                     disc: MusicController.defaultDisc)
        /// Pochette noir et blanc : métal argenté.
        static let neutral = Colors(
            tints: [NSColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 1)], coverage: [0, 0], strength: 1,
            disc: NSColor(srgbRed: 0.45, green: 0.46, blue: 0.5, alpha: 1)
        )
    }

    struct Swatch { var hue: Double; var sat: Double; var val: Double; var share: Double }

    /// Analyse par surface : chaque couleur pèse selon la place qu'elle occupe vraiment.
    static func analyze(_ image: NSImage) -> (swatches: [Swatch], chromaFraction: Double)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let bins = 36
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: bins)
        var chromatic = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let (hue, s, v) = hsv(r, g, b)
            // Blancs, gris et noirs : neutres (ils rendent le métal plus argenté, pas coloré).
            guard v > 0.14, s > 0.1 else { continue }
            chromatic += 1
            var wgt = 0.3 + s
            if v < 0.3 { wgt *= v / 0.3 }
            let bin = min(Int(hue * Double(bins)), bins - 1)
            weight[bin] += wgt
            sums[bin].0 += r * wgt; sums[bin].1 += g * wgt; sums[bin].2 += b * wgt
        }
        let chromaFraction = Double(chromatic) / Double(w * h)
        guard chromaFraction > 0.04 else { return ([], chromaFraction) }

        let smooth = (0..<bins).map { i in
            weight[(i + bins - 1) % bins] * 0.5 + weight[i] + weight[(i + 1) % bins] * 0.5
        }
        let order = (0..<bins).sorted { smooth[$0] > smooth[$1] }
        var picked: [Int] = []
        for i in order {
            if picked.count == 3 { break }
            // Un accent doit couvrir au moins 12 % de la surface de la couleur dominante.
            if let first = picked.first, smooth[i] < smooth[first] * 0.12 { break }
            let farEnough = picked.allSatisfy { p in let d = abs(p - i); return min(d, bins - d) >= 5 }
            if farEnough { picked.append(i) }
        }

        var swatches: [Swatch] = []
        for bin in picked {
            var r = 0.0, g = 0.0, b = 0.0, ws = 0.0
            for j in [-1, 0, 1] {
                let k = (bin + j + bins) % bins
                r += sums[k].0; g += sums[k].1; b += sums[k].2; ws += weight[k]
            }
            guard ws > 0 else { continue }
            let (hue, sat, val) = hsv(r / ws, g / ws, b / ws)
            swatches.append(Swatch(hue: hue, sat: sat, val: val, share: smooth[bin] / smooth[picked[0]]))
        }
        return (swatches, chromaFraction)
    }

    static func extract(from image: NSImage) -> Colors? {
        guard let (swatches, chromaFraction) = analyze(image) else { return nil }
        guard let main = swatches.first else { return .neutral }

        // Teinte fidèle : vraie nuance, saturation seulement renforcée pour rester visible sur le métal.
        func metal(_ s: Swatch) -> NSColor {
            let c = NSColor(hue: s.hue, saturation: min(max(s.sat * 1.5, 0.28), 0.95),
                            brightness: min(max(s.val * 1.15, 0.72), 0.95), alpha: 1)
            return c.usingColorSpace(.sRGB) ?? c
        }
        var tints = [metal(main)]
        var coverage: [Float] = []
        for (i, accent) in swatches.dropFirst().enumerated() {
            tints.append(metal(accent))
            coverage.append(Float(min(accent.share, 1)) * (i == 0 ? 0.5 : 0.4))
        }
        while coverage.count < 2 { coverage.append(0) }

        let disc = NSColor(hue: main.hue, saturation: min(max(main.sat * 1.3, 0.25), 0.85),
                           brightness: min(max(main.val * 0.95, 0.5), 0.8), alpha: 1)
        let strength = Float(min(max(0.5 + chromaFraction, 0.6), 1))
        return Colors(tints: tints, coverage: coverage, strength: strength, disc: disc.usingColorSpace(.sRGB) ?? disc)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}

/// Repli quand Musique ne fournit pas la pochette (fréquent pour le streaming) :
/// recherche publique d'Apple (iTunes Search API), sans clé.
/// Pochette de secours (morceau sans image dans Musique) : uniquement si la recherche Apple
/// retrouve exactement ce morceau (ou son album) — jamais une pochette au hasard.
enum ArtworkSearch {
    static func find(track: Track, completion: @escaping (NSImage?) -> Void) {
        TrackLink.lookup(track: track) { result in
            guard let small = result?["artworkUrl100"] as? String,
                  let big = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600"))
            else { return completion(nil) }
            URLSession.shared.dataTask(with: big) { data, _, _ in
                completion(data.flatMap { NSImage(data: $0) })
            }.resume()
        }
    }
}

// MARK: - Lien Apple Music du morceau

enum LinkStatus: Hashable {
    case loading, copied, failed
    var symbol: String {
        switch self {
        case .loading: return "link"
        case .copied: return "checkmark"
        case .failed: return "xmark"
        }
    }
}

/// Retrouve le lien music.apple.com du morceau via la recherche publique d'Apple
/// (Musique ne l'expose pas en AppleScript). On ne copie qu'un résultat qui correspond vraiment.
enum TrackLink {
    private static var cache: [String: URL] = [:]

    static func find(track: Track, completion: @escaping (URL?) -> Void) {
        if let cached = cache[track.id] { return completion(cached) }
        let local = (Locale.current.region?.identifier ?? "US").uppercased()
        lookup(track: track, songOnly: true) { result in
            guard let link = (result?["trackViewUrl"] as? String).flatMap(URL.init(string:)),
                  var comps = URLComponents(url: link, resolvingAgainstBaseURL: false)
            else { return completion(nil) }
            // Lien propre, sans paramètres de suivi, converti vers le pays de l'utilisateur.
            let kept = comps.queryItems?.filter { $0.name == "i" }
            comps.queryItems = kept
            if local != "US" { comps.path = comps.path.replacingOccurrences(of: "/us/", with: "/\(local.lowercased())/") }
            let url = comps.url ?? link
            DispatchQueue.main.async { cache[track.id] = url }
            completion(url)
        }
    }

    /// Résultat de la recherche Apple qui correspond vraiment au morceau.
    /// `songOnly` faux : accepte aussi un autre titre du même album (même pochette).
    static func lookup(track: Track, songOnly: Bool = false, completion: @escaping ([String: Any]?) -> Void) {
        let local = (Locale.current.region?.identifier ?? "US").uppercased()
        // Le catalogue de recherche local omet parfois des versions (souvent explicites) : repli sur les États-Unis.
        let stores = local == "US" ? ["US"] : [local, "US"]
        search(track: track, songOnly: songOnly, stores: stores[...], completion: completion)
    }

    private static func search(track: Track, songOnly: Bool, stores: ArraySlice<String>,
                               completion: @escaping ([String: Any]?) -> Void) {
        guard let store = stores.first else { return completion(nil) }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: "\(track.artist) \(track.title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "50"),
            .init(name: "country", value: store),
        ]
        guard let url = comps.url else { return completion(nil) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("PillMusic", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let results = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["results"] as? [[String: Any]] ?? []
            if let best = bestMatch(in: results, for: track) ?? (songOnly ? nil : albumMatch(in: results, for: track)) {
                completion(best)
            } else {
                search(track: track, songOnly: songOnly, stores: stores.dropFirst(), completion: completion)
            }
        }.resume()
    }

    private static func artistMatches(_ a: String, _ artist: String) -> Bool {
        // Strict : l'artiste exact, éventuellement suivi d'invités — jamais une reprise ou un karaoké.
        if a == artist { return true }
        return [" &", ",", " feat", " x "].contains { a.hasPrefix(artist + $0) || artist.hasPrefix(a + $0) }
    }

    /// Un autre titre du même album, du même artiste : sa pochette est la bonne.
    private static func albumMatch(in results: [[String: Any]], for track: Track) -> [String: Any]? {
        let artist = normalize(track.artist), album = fold(track.album)
        guard !album.isEmpty else { return nil }
        return results.first {
            fold($0["collectionName"] as? String ?? "") == album
                && artistMatches(normalize($0["artistName"] as? String ?? ""), artist)
        }
    }

    private static func bestMatch(in results: [[String: Any]], for track: Track) -> [String: Any]? {
        let title = normalize(track.title), artist = normalize(track.artist), album = normalize(track.album)
        func score(_ r: [String: Any]) -> Int {
            let t = normalize(r["trackName"] as? String ?? "")
            let a = normalize(r["artistName"] as? String ?? "")
            let c = normalize(r["collectionName"] as? String ?? "")
            guard t == title, artistMatches(a, artist) else { return -1 }
            let fullName = fold(r["trackName"] as? String ?? ""), fullCollection = fold(r["collectionName"] as? String ?? "")
            var s = 1
            if fullName == fold(track.title) { s += 3 }
            if !track.album.isEmpty, fullCollection == fold(track.album) { s += 4 }
            else if !album.isEmpty, c == album { s += 2 }
            // Versions alternatives (drumless, live, karaoké…) seulement si c'est ce qu'on écoute.
            let source = fold(track.title + " " + track.album)
            for word in variantWords where (fullName + " " + fullCollection).contains(word) && !source.contains(word) { s -= 3 }
            if (r["trackExplicitness"] as? String) == "explicit" { s += 1 }
            return s
        }
        return results.map({ ($0, score($0)) }).filter({ $0.1 >= 0 }).max(by: { $0.1 < $1.1 })?.0
    }

    private static let variantWords = ["drumless", "instrumental", "karaoke", "live", "remix", "acoustic", "sped up",
                                       "slowed", "acapella", "a cappella", "edit", "version", "cover", "remaster"]

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minuscules, sans accents, sans mentions entre parenthèses (« feat. », « Remastered »…).
    private static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for sep in [" (", " [", " - "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
