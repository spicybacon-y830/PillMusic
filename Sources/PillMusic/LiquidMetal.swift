import AppKit
import MetalKit
import SwiftUI

/// Portage Metal fidèle du shader « LiquidMetal » de Paper (@paper-design/shaders 0.0.82),
/// avec les réglages exacts du design. Compilé au lancement : pas besoin de Xcode.
struct LiquidMetal: NSViewRepresentable {
    var tints: [NSColor]
    var speed: Float
    var boostToken: Int

    func makeNSView(context: Context) -> LiquidMetalView {
        LiquidMetalView()
    }

    func updateNSView(_ view: LiquidMetalView, context: Context) {
        view.setTints(tints)
        view.targetSpeed = speed
        if boostToken != view.lastBoostToken {
            view.lastBoostToken = boostToken
            view.boost()
        }
    }
}

final class LiquidMetalView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var tint: SIMD4<Float>
        var tint2: SIMD4<Float>
        var tint3: SIMD4<Float>
        var back: SIMD4<Float>
        var viewSize: SIMD2<Float>
        var time: Float
        var softness: Float
        var repetition: Float
        var shiftRed: Float
        var shiftBlue: Float
        var distortion: Float
        var contour: Float
        var angle: Float
        var designRes: Float
    }

    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var shapeTexture: MTLTexture?
    private var sampler: MTLSamplerState?

    private static let paperRed = SIMD4<Float>(0xCA / 255, 0x05 / 255, 0x03 / 255, 1)
    private var currentTints = [paperRed, paperRed, paperRed]
    private var targetTints = [paperRed, paperRed, paperRed]
    var targetSpeed: Float = 1
    var lastBoostToken = 0
    private var speed: Float = 1
    private var boostAmount: Float = 0
    // Démarre à une phase arbitraire, comme le `frame` du design.
    private var time: Float = Float.random(in: 0...200)
    private var lastTimestamp: CFTimeInterval = CACurrentMediaTime()

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        wantsLayer = true
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        preferredFramesPerSecond = 60
        framebufferOnly = true
        if let device { setup(device) }
    }

    required init(coder: NSCoder) { fatalError() }

    // Les clics traversent la vue Metal pour atteindre le bouton SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Couleur dominante + 2 accents de la pochette.
    func setTints(_ colors: [NSColor]) {
        guard let first = colors.first else { return }
        for i in 0..<3 {
            let color = i < colors.count ? colors[i] : first
            let c = color.usingColorSpace(.sRGB) ?? color
            targetTints[i] = SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1)
        }
    }

    /// Petite accélération du métal liquide au clic.
    func boost() { boostAmount = 7 }

    private func setup(_ device: MTLDevice) {
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "lm_vertex")
            desc.fragmentFunction = library.makeFunction(name: "lm_fragment")
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("PillMusic: shader indisponible – \(error)")
        }
        shapeTexture = ShapeTexture.make(device: device)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTimestamp, 0.1))
        lastTimestamp = now

        // Transitions douces de vitesse et de couleur.
        speed += (targetSpeed - speed) * min(1, dt * 3)
        boostAmount *= exp(-dt * 2.6)
        time += dt * (speed + boostAmount)
        var tintSettled = true
        for i in 0..<3 {
            currentTints[i] += (targetTints[i] - currentTints[i]) * min(1, dt * 3.5)
            if simd_reduce_max(simd_abs(targetTints[i] - currentTints[i])) >= 0.002 { tintSettled = false }
        }

        // À l'arrêt (pause) : image figée, redessinée lentement (10 i/s) pour économiser la batterie.
        // On continue de redessiner : macOS peut vider la vue Metal (veille, changement de bureau).
        let moving = speed + boostAmount > 0.002
        if !moving { speed = 0; boostAmount = 0 }
        let fps = (moving || !tintSettled) ? 60 : 10
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }

        guard let window, window.occlusionState.contains(.visible),
              let pipeline, let queue, let shapeTexture, let sampler,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        var u = Uniforms(
            tint: currentTints[0],
            tint2: currentTints[1],
            tint3: currentTints[2],
            back: SIMD4(0, 0, 0, 0),
            viewSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            time: time,
            softness: 0.1, repetition: 1.99, shiftRed: 0.3, shiftBlue: 0.3,
            distortion: 0.07, contour: 0.54, angle: 70,
            designRes: 320
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(shapeTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    #define PI 3.14159265358979323846

    struct VOut { float4 position [[position]]; };

    struct Uniforms {
        float4 tint;
        float4 tint2;
        float4 tint3;
        float4 back;
        float2 viewSize;
        float time;
        float softness;
        float repetition;
        float shiftRed;
        float shiftBlue;
        float distortion;
        float contour;
        float angle;
        float designRes;
    };

    vertex VOut lm_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut o;
        o.position = float4(p[vid], 0.0, 1.0);
        return o;
    }

    // mod() GLSL (différent de fmod pour les négatifs)
    static float2 gmod2(float2 x, float y) { return x - y * floor(x / y); }
    static float3 gmod3(float3 x, float y) { return x - y * floor(x / y); }

    static float2 rotate2(float2 uv, float th) {
        return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
    }

    static float3 permute(float3 x) { return gmod3(((x * 34.0) + 1.0) * x, 289.0); }

    static float snoise(float2 v) {
        const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
        float2 i = floor(v + dot(v, C.yy));
        float2 x0 = v - i + dot(i, C.xx);
        float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
        float4 x12 = x0.xyxy + C.xxzz;
        x12.xy -= i1;
        i = gmod2(i, 289.0);
        float3 p = permute(permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
        float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
        m = m * m;
        m = m * m;
        float3 x = 2.0 * fract(p * C.www) - 1.0;
        float3 h = abs(x) - 0.5;
        float3 ox = floor(x + 0.5);
        float3 a0 = x - ox;
        m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
        float3 g;
        g.x = a0.x * x0.x + h.x * x0.y;
        g.yz = a0.yz * x12.xz + h.yz * x12.yw;
        return 130.0 * dot(m, g);
    }

    static float getColorChanges(float c1, float c2, float stripe_p, float3 w, float blur, float bump, float tint, float tintA) {
        float ch = mix(c2, c1, smoothstep(0.0, 2.0 * blur, stripe_p));
        float border = w[0];
        ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));
        bump = smoothstep(0.2, 0.8, bump);
        border = w[0] + 0.4 * (1.0 - bump) * w[1];
        ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));
        border = w[0] + 0.5 * (1.0 - bump) * w[1];
        ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));
        border = w[0] + w[1];
        ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));
        float gradient_t = (stripe_p - w[0] - w[1]) / w[2];
        float gradient = mix(c1, c2, smoothstep(0.0, 1.0, gradient_t));
        ch = mix(ch, gradient, smoothstep(border, border + 0.5 * blur, stripe_p));
        // Teinte appliquée en « color burn »
        ch = mix(ch, 1.0 - min(1.0, (1.0 - ch) / max(tint, 0.0001)), tintA);
        return ch;
    }

    static float blurEdge3x3(texture2d<float> tex, sampler s, float2 uv, float2 dudx, float2 dudy, float radius, float centerSample) {
        float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
        float2 r = radius * texel;
        float sum = 4.0 * centerSample;
        gradient2d g = gradient2d(dudx, dudy);
        sum += 2.0 * tex.sample(s, uv + float2(0.0, -r.y), g).r;
        sum += 2.0 * tex.sample(s, uv + float2(0.0, r.y), g).r;
        sum += 2.0 * tex.sample(s, uv + float2(-r.x, 0.0), g).r;
        sum += 2.0 * tex.sample(s, uv + float2(r.x, 0.0), g).r;
        sum += tex.sample(s, uv + float2(-r.x, -r.y), g).r;
        sum += tex.sample(s, uv + float2(r.x, -r.y), g).r;
        sum += tex.sample(s, uv + float2(-r.x, r.y), g).r;
        sum += tex.sample(s, uv + float2(r.x, r.y), g).r;
        return sum / 16.0;
    }

    fragment float4 lm_fragment(VOut in [[stage_in]],
                                constant Uniforms& u [[buffer(0)]],
                                texture2d<float> tex [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
        const float firstFrameOffset = 2.8;
        float t = 0.3 * (u.time + firstFrameOffset);

        float2 uv = in.position.xy / u.viewSize;
        float2 dudx = dfdx(uv);
        float2 dudy = dfdy(uv);
        float4 img = tex.sample(smp, uv, gradient2d(dudx, dudy));

        float cycleWidth = u.repetition;

        float2 rotatedUV = uv - float2(0.5);
        float angle = (-u.angle + 70.0) * PI / 180.0;
        float cosA = cos(angle);
        float sinA = sin(angle);
        rotatedUV = float2(rotatedUV.x * cosA - rotatedUV.y * sinA,
                           rotatedUV.x * sinA + rotatedUV.y * cosA) + float2(0.5);

        float edge = blurEdge3x3(tex, smp, uv, dudx, dudy, 6.0, img.r);
        edge = pow(edge, 1.6);
        edge *= mix(0.0, 1.0, smoothstep(0.0, 0.4, u.contour));

        float opacity = img.g;

        float diagBLtoTR = rotatedUV.x - rotatedUV.y;
        float diagTLtoBR = rotatedUV.x + rotatedUV.y;

        float3 color1 = float3(0.98, 0.98, 1.0);
        float3 color2 = float3(0.1, 0.1, 0.1 + 0.1 * smoothstep(0.7, 1.3, diagTLtoBR));

        float2 grad_uv = uv - 0.5;
        float dist = length(grad_uv + float2(0.0, 0.2 * diagBLtoTR));
        grad_uv = rotate2(grad_uv, (0.25 - 0.2 * diagBLtoTR) * PI);
        float direction = grad_uv.x;

        float bump = pow(1.8 * dist, 1.2);
        bump = 1.0 - bump;
        bump *= pow(uv.y, 0.3);

        float thin_strip_1_ratio = 0.12 / cycleWidth * (1.0 - 0.4 * bump);
        float thin_strip_2_ratio = 0.07 / cycleWidth * (1.0 + 0.4 * bump);
        float wide_strip_ratio = (1.0 - thin_strip_1_ratio - thin_strip_2_ratio);
        float thin_strip_1_width = cycleWidth * thin_strip_1_ratio;
        float thin_strip_2_width = cycleWidth * thin_strip_2_ratio;

        float noise = snoise(uv - t);
        edge += (1.0 - edge) * u.distortion * noise;

        direction += diagBLtoTR;
        float contour = 0.0;
        direction -= 2.0 * noise * diagBLtoTR * (smoothstep(0.0, 1.0, edge) * (1.0 - smoothstep(0.0, 1.0, edge)));
        direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, u.contour));
        direction -= 1.7 * edge * smoothstep(0.5, 1.0, u.contour);
        direction += 0.2 * pow(u.contour, 4.0) * (1.0 - smoothstep(0.0, 1.0, edge));

        bump *= clamp(pow(uv.y, 0.1), 0.3, 1.0);
        direction *= (0.1 + (1.1 - edge) * bump);
        direction *= (0.4 + 0.6 * (1.0 - smoothstep(0.5, 1.0, edge)));
        direction += 0.18 * (smoothstep(0.1, 0.2, uv.y) * (1.0 - smoothstep(0.2, 0.4, uv.y)));
        direction += 0.03 * (smoothstep(0.1, 0.2, 1.0 - uv.y) * (1.0 - smoothstep(0.2, 0.4, 1.0 - uv.y)));
        direction *= (0.5 + 0.5 * pow(uv.y, 2.0));
        direction *= cycleWidth;
        direction -= t;

        // Palette de la pochette : la dominante et un accent suivent les bandes du métal,
        // le 2e accent passe en reflet diagonal.
        float flow = 0.5 + 0.5 * sin((direction * 0.5 + 0.35 * noise) * 2.0 * PI);
        float3 tc = mix(u.tint.rgb, u.tint2.rgb, smoothstep(0.3, 0.7, flow));
        float sweep = 0.5 + 0.5 * sin((uv.x - uv.y) * 4.0 + t * 1.7 + 2.0 * noise);
        tc = mix(tc, u.tint3.rgb, 0.85 * smoothstep(0.6, 0.95, sweep));

        float colorDispersion = clamp(1.0 - bump, 0.0, 1.0);
        float dispersionRed = colorDispersion;
        dispersionRed += 0.03 * bump * noise;
        dispersionRed += 5.0 * (smoothstep(-0.1, 0.2, uv.y) * (1.0 - smoothstep(0.1, 0.5, uv.y))) * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 1.0, bump)));
        dispersionRed -= diagBLtoTR;

        float dispersionBlue = colorDispersion;
        dispersionBlue *= 1.3;
        dispersionBlue += (smoothstep(0.0, 0.4, uv.y) * (1.0 - smoothstep(0.1, 0.8, uv.y))) * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 0.8, bump)));
        dispersionBlue -= 0.2 * edge;

        dispersionRed *= (u.shiftRed / 20.0);
        dispersionBlue *= (u.shiftBlue / 20.0);

        float softness = 0.05 * u.softness;
        float blur = softness + 0.5 * smoothstep(1.0, 10.0, u.repetition) * smoothstep(0.0, 1.0, edge);
        float smallCanvasT = 1.0 - smoothstep(100.0, 500.0, u.designRes);
        blur += smallCanvasT * smoothstep(0.0, 1.0, edge);
        float rExtraBlur = softness * (0.05 + 0.1 * (u.shiftRed / 20.0) * bump);
        float gExtraBlur = softness * 0.05 / max(0.001, abs(1.0 - diagBLtoTR));
        blur += 0.3 * contour;

        float3 w = float3(thin_strip_1_width, thin_strip_2_width, wide_strip_ratio);
        w[1] -= 0.02 * smoothstep(0.0, 1.0, edge + bump);
        float stripe_r = fract(direction + dispersionRed);
        float r = getColorChanges(color1.r, color2.r, stripe_r, w, blur + fwidth(stripe_r) + rExtraBlur, bump, tc.r, u.tint.a);
        float stripe_g = fract(direction);
        float g = getColorChanges(color1.g, color2.g, stripe_g, w, blur + fwidth(stripe_g) + gExtraBlur, bump, tc.g, u.tint.a);
        float stripe_b = fract(direction - dispersionBlue);
        float b = getColorChanges(color1.b, color2.b, stripe_b, w, blur + fwidth(stripe_b), bump, tc.b, u.tint.a);

        float3 color = clamp(float3(r, g, b), 0.0, 1.0);
        if (any(isnan(color))) { color = float3(0.5); }
        opacity = isnan(opacity) ? 0.0 : opacity;
        color *= opacity;

        float3 bgColor = u.back.rgb * u.back.a;
        color = color + bgColor * (1.0 - opacity);
        opacity = opacity + u.back.a * (1.0 - opacity);

        color += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

        return float4(color, opacity);
    }
    """#
}

/// Reproduit `toProcessedLiquidMetal` de Paper : un champ de Poisson calculé sur la forme
/// (canal R = profondeur depuis le bord, canal G = masque de la forme).
enum ShapeTexture {
    static func make(device: MTLDevice) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: "liquid-shape", withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let ow = image.width, oh = image.height
        let workingSize = 512.0
        let scale = workingSize / Double(min(ow, oh))
        let w = Int((Double(ow) * scale).rounded()), h = Int((Double(oh) * scale).rounded())

        // 1. Masque de la forme à la taille de travail
        let working = rgba(image, w, h)
        var shape = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { shape[i] = working[i * 4 + 3] == 0 ? 0 : 1 }

        var interior: [Int] = []
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                guard shape[idx] == 1 else { continue }
                var boundary = x == 0 || x == w - 1 || y == 0 || y == h - 1
                if !boundary {
                    boundary = shape[idx - 1] == 0 || shape[idx + 1] == 0 || shape[idx - w] == 0 || shape[idx + w] == 0
                        || shape[idx - w - 1] == 0 || shape[idx - w + 1] == 0 || shape[idx + w - 1] == 0 || shape[idx + w + 1] == 0
                }
                if !boundary { interior.append(idx) }
            }
        }

        // 2. Résolution SOR rouge/noir (40 itérations, ω = 1.9), comme Paper
        var neighbors = [Int](repeating: -1, count: interior.count * 4)
        for (i, idx) in interior.enumerated() {
            let x = idx % w, y = idx / w
            neighbors[i * 4 + 0] = x < w - 1 && shape[idx + 1] == 1 ? idx + 1 : -1
            neighbors[i * 4 + 1] = x > 0 && shape[idx - 1] == 1 ? idx - 1 : -1
            neighbors[i * 4 + 2] = y > 0 && shape[idx - w] == 1 ? idx - w : -1
            neighbors[i * 4 + 3] = y < h - 1 && shape[idx + w] == 1 ? idx + w : -1
        }
        var red: [Int] = [], black: [Int] = []
        for (i, idx) in interior.enumerated() {
            if (idx % w + idx / w) % 2 == 0 { red.append(i) } else { black.append(i) }
        }
        var u = [Float](repeating: 0, count: w * h)
        let omega: Float = 1.9, c: Float = 0.01
        u.withUnsafeMutableBufferPointer { u in
            neighbors.withUnsafeBufferPointer { nb in
                interior.withUnsafeBufferPointer { interior in
                    func pass(_ set: [Int]) {
                        for i in set {
                            let idx = interior[i]
                            var sum: Float = 0
                            for k in 0..<4 { let n = nb[i * 4 + k]; if n >= 0 { sum += u[n] } }
                            u[idx] = omega * ((c + sum) / 4) + (1 - omega) * u[idx]
                        }
                    }
                    for _ in 0..<40 { pass(red); pass(black) }
                }
            }
        }
        var maxVal: Float = 0
        for idx in interior where u[idx] > maxVal { maxVal = u[idx] }
        if maxVal == 0 { maxVal = 1 }

        // 3. Image de profondeur, puis remise à la taille d'origine
        var depth = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            if shape[i] == 0 {
                depth[i * 4] = 0; depth[i * 4 + 1] = 0; depth[i * 4 + 2] = 0; depth[i * 4 + 3] = 0
            } else {
                let gray = UInt8(max(0, min(255, 255 * (1 - u[i] / maxVal))))
                depth[i * 4] = gray; depth[i * 4 + 1] = gray; depth[i * 4 + 2] = gray; depth[i * 4 + 3] = 255
            }
        }
        guard let depthImage = makeImage(&depth, w, h) else { return nil }
        let up = rgba(depthImage, ow, oh)
        let original = rgba(image, ow, oh)

        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        for i in 0..<(ow * oh) {
            let a = original[i * 4 + 3]
            let ua = up[i * 4 + 3]
            if a == 0 {
                out[i * 4] = 255; out[i * 4 + 1] = 0
            } else {
                // Valeur dé-prémultipliée, comme getImageData
                let r = ua == 0 ? 0 : min(255, Int(up[i * 4]) * 255 / Int(ua))
                out[i * 4] = UInt8(r); out[i * 4 + 1] = a
            }
            out[i * 4 + 2] = 255; out[i * 4 + 3] = 255
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: ow, height: oh, mipmapped: true)
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, ow, oh), mipmapLevel: 0, withBytes: out, bytesPerRow: ow * 4)
        if let q = device.makeCommandQueue(), let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return texture
    }

    private static func rgba(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    private static func makeImage(_ data: inout [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        data.withUnsafeMutableBytes { ptr in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
