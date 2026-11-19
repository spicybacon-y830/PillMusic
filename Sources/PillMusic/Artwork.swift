import AppKit

/// Couleurs dérivées de la pochette pour teinter le shader du bouton.
enum Palette {
    struct Colors {
        /// [dominante, accent 1, accent 2]
        var tints: [NSColor]
        var disc: NSColor

        static let fallback = Colors(tints: [MusicController.defaultTint], disc: MusicController.defaultDisc)
        /// Pochette noir et blanc : métal argenté.
        static let neutral = Colors(
            tints: [NSColor(srgbRed: 0.86, green: 0.87, blue: 0.9, alpha: 1)],
            disc: NSColor(srgbRed: 0.45, green: 0.46, blue: 0.5, alpha: 1)
        )
    }

    static func extract(from image: NSImage) -> Colors? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 48, h = 48
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
        var totalChroma = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let (hue, s, v) = hsv(r, g, b)
            guard v > 0.15, s > 0.18 else { continue }
            // Favorise les couleurs vives et pas trop sombres.
            let score = s * s * (v < 0.35 ? v : 1.0)
            totalChroma += score
            let bin = min(Int(hue * Double(bins)), bins - 1)
            weight[bin] += score
            sums[bin].0 += r * score; sums[bin].1 += g * score; sums[bin].2 += b * score
        }

        guard totalChroma / Double(w * h) > 0.03 else { return .neutral }

        // Pics de teinte (lissés avec les voisines), du plus présent au moins présent.
        let smooth = (0..<bins).map { i in
            weight[(i + bins - 1) % bins] * 0.5 + weight[i] + weight[(i + 1) % bins] * 0.5
        }
        let order = (0..<bins).sorted { smooth[$0] > smooth[$1] }

        // Dominante, puis jusqu'à 2 accents éloignés d'au moins 50° et assez présents (≥ 3 %).
        var picked: [Int] = []
        for i in order {
            if picked.count == 3 { break }
            if !picked.isEmpty && smooth[i] < totalChroma * 0.03 { break }
            let farEnough = picked.allSatisfy { p in
                let d = abs(p - i)
                return min(d, bins - d) >= 5
            }
            if farEnough { picked.append(i) }
        }

        var tints: [(hue: Double, sat: Double)] = []
        for bin in picked {
            var r = 0.0, g = 0.0, b = 0.0, ws = 0.0
            for j in [-1, 0, 1] {
                let k = (bin + j + bins) % bins
                r += sums[k].0; g += sums[k].1; b += sums[k].2; ws += weight[k]
            }
            guard ws > 0 else { continue }
            let (hue, sat, _) = hsv(r / ws, g / ws, b / ws)
            tints.append((hue, sat))
        }
        guard let main = tints.first else { return .neutral }

        // Normalisé pour rester proche du rendu Paper (#CA0503 sur fond #C11F42).
        func metal(_ t: (hue: Double, sat: Double), brightness: Double) -> NSColor {
            let c = NSColor(hue: t.hue, saturation: min(max(t.sat * 1.25, 0.6), 0.98), brightness: brightness, alpha: 1)
            return c.usingColorSpace(.sRGB) ?? c
        }
        var colors = [metal(main, brightness: 0.8)]
        for accent in tints.dropFirst() { colors.append(metal(accent, brightness: 0.85)) }
        // Une seule couleur : variante plus claire pour garder du relief.
        if colors.count == 1 { colors.append(metal((main.hue, main.sat * 0.8), brightness: 0.95)) }

        let discBase = NSColor(hue: main.hue, saturation: min(max(main.sat * 1.05, 0.5), 0.86), brightness: 0.76, alpha: 1)
        return Colors(tints: colors, disc: discBase.usingColorSpace(.sRGB) ?? discBase)
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
enum ArtworkSearch {
    static func find(track: Track, completion: @escaping (NSImage?) -> Void) {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        let region = Locale.current.region?.identifier ?? "US"
        comps.queryItems = [
            .init(name: "term", value: "\(track.artist) \(track.title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
            .init(name: "country", value: region),
        ]
        guard let url = comps.url else { return completion(nil) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("PillMusic", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let small = first["artworkUrl100"] as? String,
                  let big = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600"))
            else { return completion(nil) }
            URLSession.shared.dataTask(with: big) { data, _, _ in
                completion(data.flatMap { NSImage(data: $0) })
            }.resume()
        }.resume()
    }
}
