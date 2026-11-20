import AppKit
import SwiftUI
import CoreText

let args = CommandLine.arguments
if args.count == 4, args[1] == "--render-test", let art = NSImage(contentsOfFile: args[2]) {
    ShaderRenderer.renderTest(artwork: art, to: URL(fileURLWithPath: args[3]))
    exit(0)
}

if args.count >= 3, args[1] == "--render-pill" {
    // Usage : PillMusic --render-pill sortie.png [pochette]
    MainActor.assumeIsolated {
        if let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
            for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
        ShaderRenderer.drawsInLayer = false
        let music = MusicController()
        music.loadDemo(artwork: args.count > 3 ? NSImage(contentsOfFile: args[3]) : nil)
        let settings = Settings()
        ShaderRenderer.shared.pointSize = Design.disc * settings.size.scale
        ShaderRenderer.shared.setPalette(Palette.extract(from: music.artwork ?? NSImage()) ?? .fallback)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        var images: [CGImage] = []
        for (expanded, dark) in [(false, false), (true, false), (true, true)] {
            let ui = UIState(); ui.shown = true; ui.forceExpanded = expanded
            let s = settings.size.scale
            let view = PillRoot(music: music, settings: settings, ui: ui, lyrics: LyricsModel(music: music))
                .frame(width: (Design.width + Design.skipExtra) * s + PillPanel.margin * 2,
                       height: Design.height * s + PillPanel.marginY * 2)
                .background(Color(white: 0.8))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view); r.scale = 3
            if let img = r.cgImage { images.append(img) }
        }
        let w = images.map(\.width).max() ?? 1, h = images.map(\.height).reduce(0, +)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var y = h
        for img in images { y -= img.height; ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height)) }
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
    }
    exit(0)
}

if args.count == 5, args[1] == "--link-test" {
    // Usage : PillMusic --link-test artiste titre album
    let t = Track(id: UUID().uuidString, title: args[3], artist: args[2], album: args[4], duration: 0)
    TrackLink.find(track: t) { url in print(url?.absoluteString ?? "introuvable"); exit(0) }
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
