using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace PillMusic;

/// Portage fidèle du shader « LiquidMetal » de Paper (@paper-design/shaders), identique à la version Mac,
/// calculé sur le processeur : le bouton ne fait qu'une soixantaine de pixels de côté.
sealed class LiquidMetal
{
    public event Action? FrameReady;
    public WriteableBitmap? Frame { get; private set; }

    /// Taille du bouton en pixels physiques.
    public int Pixels { get => px; set { if (value != px) { px = Math.Max(8, value); needsFrame = true; Wake(); } } }
    public double TargetSpeed { get => targetSpeed; set { if (value != targetSpeed) { targetSpeed = value; Wake(); } } }
    /// Fenêtre cachée : la boucle s'endort.
    public bool Visible { get => visible; set { visible = value; if (value) Wake(); } }

    int px = 80;
    double targetSpeed = 1;
    bool visible = true;

    readonly float[] shapeR, shapeG; // profondeur depuis le bord, masque
    const int ShapeSize = 320;
    float[] mipR = Array.Empty<float>(), mipG = Array.Empty<float>();
    int mipSize;

    static readonly float[] PaperRed = { 0xCA / 255f, 0x05 / 255f, 0x03 / 255f, 1 };
    readonly float[][] current = { (float[])PaperRed.Clone(), (float[])PaperRed.Clone(), (float[])PaperRed.Clone() };
    readonly float[][] target = { (float[])PaperRed.Clone(), (float[])PaperRed.Clone(), (float[])PaperRed.Clone() };
    double speed = 1, boost;
    // Démarre à une phase arbitraire, comme le `frame` du design.
    double time = new Random().NextDouble() * 200;
    bool needsFrame = true;
    readonly DispatcherTimer timer;
    DateTime last = DateTime.UtcNow;

    // Tampons de calcul (deux passes : la seconde calcule fwidth comme le GPU, par blocs 2×2).
    float[] sR = Array.Empty<float>(), sG = Array.Empty<float>(), sB = Array.Empty<float>();
    float[] pBlur = Array.Empty<float>(), pRx = Array.Empty<float>(), pGx = Array.Empty<float>(), pBump = Array.Empty<float>();
    float[] pW0 = Array.Empty<float>(), pW1 = Array.Empty<float>(), pW2 = Array.Empty<float>();
    float[] pTc = Array.Empty<float>(), pOp = Array.Empty<float>();
    byte[] pixels = Array.Empty<byte>();

    public LiquidMetal()
    {
        (shapeR, shapeG) = LoadShape();
        timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1 / Power.ShaderFPS) };
        timer.Tick += (_, _) => Tick();
        Power.Changed += () => { timer.Interval = TimeSpan.FromSeconds(1 / Power.ShaderFPS); };
        Wake();
    }

    static (float[], float[]) LoadShape()
    {
        var r = new float[ShapeSize * ShapeSize];
        var g = new float[ShapeSize * ShapeSize];
        try
        {
            var img = new BitmapImage(new Uri("pack://application:,,,/Assets/liquid-shape-processed.png"));
            var conv = new FormatConvertedBitmap(img, PixelFormats.Bgra32, null, 0);
            var data = new byte[ShapeSize * ShapeSize * 4];
            conv.CopyPixels(data, ShapeSize * 4, 0);
            for (int i = 0; i < r.Length; i++) { r[i] = data[i * 4 + 2] / 255f; g[i] = data[i * 4 + 1] / 255f; }
        }
        catch
        {
            // Disque plein si la ressource manque.
            for (int y = 0; y < ShapeSize; y++)
                for (int x = 0; x < ShapeSize; x++)
                {
                    float dx = (x + 0.5f) / ShapeSize - 0.5f, dy = (y + 0.5f) / ShapeSize - 0.5f;
                    float d = MathF.Sqrt(dx * dx + dy * dy);
                    g[y * ShapeSize + x] = d < 0.5f ? 1 : 0;
                    r[y * ShapeSize + x] = d < 0.5f ? Math.Clamp(d * 2, 0, 1) : 1;
                }
        }
        return (r, g);
    }

    /// Couleur dominante + 2 accents. 4e composante : intensité (dominante) ou part de l'accent.
    public void SetPalette(PaletteColors p)
    {
        for (int i = 0; i < 3; i++)
        {
            var c = i < p.Tints.Length ? p.Tints[i] : p.Tints[0];
            float a = i == 0 ? p.Strength : (i - 1 < p.Coverage.Length ? p.Coverage[i - 1] : 0);
            target[i] = new[] { c.R / 255f, c.G / 255f, c.B / 255f, a };
        }
        Wake();
    }

    /// Rendu de test : une image tout de suite, couleurs déjà en place.
    public void RenderNow(double atTime = 11)
    {
        for (int i = 0; i < 3; i++) current[i] = (float[])target[i].Clone();
        time = atTime;
        Render();
        needsFrame = false;
        FrameReady?.Invoke();
    }

    /// Petite accélération du métal liquide au clic.
    public void Boost() { boost = 7; Wake(); }

    void Wake()
    {
        if (timer.IsEnabled) return;
        last = DateTime.UtcNow;
        timer.Start();
    }

    void Tick()
    {
        var now = DateTime.UtcNow;
        double dt = Math.Min((now - last).TotalSeconds, 0.1);
        last = now;

        speed += (targetSpeed - speed) * Math.Min(1, dt * 3);
        boost *= Math.Exp(-dt * 2.6);
        bool moving = speed + boost > 0.002;
        if (!moving) { speed = 0; boost = 0; }
        time += dt * (speed + boost);
        bool settled = true;
        for (int i = 0; i < 3; i++)
            for (int k = 0; k < 4; k++)
            {
                current[i][k] += (target[i][k] - current[i][k]) * (float)Math.Min(1, dt * 3.5);
                if (Math.Abs(target[i][k] - current[i][k]) >= 0.002f) settled = false;
            }

        // En pause : image figée, et la boucle s'endort complètement.
        if (!(moving || !settled || needsFrame || Frame == null) || !visible) { timer.Stop(); return; }
        Render();
        needsFrame = false;
        FrameReady?.Invoke();
    }

    void EnsureBuffers()
    {
        int n = px * px;
        if (sR.Length != n)
        {
            sR = new float[n]; sG = new float[n]; sB = new float[n];
            pBlur = new float[n]; pRx = new float[n]; pGx = new float[n]; pBump = new float[n];
            pW0 = new float[n]; pW1 = new float[n]; pW2 = new float[n];
            pTc = new float[n * 3]; pOp = new float[n];
            pixels = new byte[n * 4];
        }
        if (Frame == null || Frame.PixelWidth != px)
            Frame = new WriteableBitmap(px, px, 96, 96, PixelFormats.Pbgra32, null);
        // Équivalent du mipmap : forme réduite à la taille de rendu (moyenne par boîte).
        if (mipSize != px)
        {
            mipSize = px;
            mipR = new float[n]; mipG = new float[n];
            double f = (double)ShapeSize / px;
            for (int y = 0; y < px; y++)
                for (int x = 0; x < px; x++)
                {
                    int x0 = (int)(x * f), x1 = Math.Max(x0 + 1, (int)((x + 1) * f));
                    int y0 = (int)(y * f), y1 = Math.Max(y0 + 1, (int)((y + 1) * f));
                    float sr = 0, sg = 0; int c = 0;
                    for (int yy = y0; yy < Math.Min(y1, ShapeSize); yy++)
                        for (int xx = x0; xx < Math.Min(x1, ShapeSize); xx++) { sr += shapeR[yy * ShapeSize + xx]; sg += shapeG[yy * ShapeSize + xx]; c++; }
                    mipR[y * px + x] = sr / Math.Max(c, 1); mipG[y * px + x] = sg / Math.Max(c, 1);
                }
        }
    }

    /// Échantillonnage bilinéaire (bords étirés) de la forme réduite.
    float Sample(float[] tex, float u, float v)
    {
        float x = u * mipSize - 0.5f, y = v * mipSize - 0.5f;
        int x0 = (int)MathF.Floor(x), y0 = (int)MathF.Floor(y);
        float fx = x - x0, fy = y - y0;
        int Cx(int i) => Math.Clamp(i, 0, mipSize - 1);
        int a = Cx(x0), b = Cx(x0 + 1), c = Cx(y0), d = Cx(y0 + 1);
        float t0 = tex[c * mipSize + a] * (1 - fx) + tex[c * mipSize + b] * fx;
        float t1 = tex[d * mipSize + a] * (1 - fx) + tex[d * mipSize + b] * fx;
        return t0 * (1 - fy) + t1 * fy;
    }

    const float PI = MathF.PI;
    static float Fract(float x) => x - MathF.Floor(x);
    static float Mod(float x, float y) => x - y * MathF.Floor(x / y);
    static float Mix(float a, float b, float t) => a + (b - a) * t;
    static float Clamp01(float x) => Math.Clamp(x, 0f, 1f);
    static float Smooth(float e0, float e1, float x) { float t = Clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t); }
    static float Permute(float x) => Mod(((x * 34f) + 1f) * x, 289f);

    static float SNoise(float vx, float vy)
    {
        const float Cx = 0.211324865405187f, Cy = 0.366025403784439f, Cz = -0.577350269189626f, Cw = 0.024390243902439f;
        float s = (vx + vy) * Cy;
        float ix = MathF.Floor(vx + s), iy = MathF.Floor(vy + s);
        float t = (ix + iy) * Cx;
        float x0x = vx - ix + t, x0y = vy - iy + t;
        float i1x = x0x > x0y ? 1 : 0, i1y = x0x > x0y ? 0 : 1;
        float x12x = x0x + Cx - i1x, x12y = x0y + Cx - i1y;
        float x12z = x0x + Cz, x12w = x0y + Cz;
        ix = Mod(ix, 289f); iy = Mod(iy, 289f);
        float p0 = Permute(Permute(iy) + ix);
        float p1 = Permute(Permute(iy + i1y) + ix + i1x);
        float p2 = Permute(Permute(iy + 1) + ix + 1);
        float m0 = MathF.Max(0.5f - (x0x * x0x + x0y * x0y), 0);
        float m1 = MathF.Max(0.5f - (x12x * x12x + x12y * x12y), 0);
        float m2 = MathF.Max(0.5f - (x12z * x12z + x12w * x12w), 0);
        m0 *= m0; m0 *= m0; m1 *= m1; m1 *= m1; m2 *= m2; m2 *= m2;
        float xx0 = 2 * Fract(p0 * Cw) - 1, xx1 = 2 * Fract(p1 * Cw) - 1, xx2 = 2 * Fract(p2 * Cw) - 1;
        float h0 = MathF.Abs(xx0) - 0.5f, h1 = MathF.Abs(xx1) - 0.5f, h2 = MathF.Abs(xx2) - 0.5f;
        float a0 = xx0 - MathF.Floor(xx0 + 0.5f), a1 = xx1 - MathF.Floor(xx1 + 0.5f), a2 = xx2 - MathF.Floor(xx2 + 0.5f);
        m0 *= 1.79284291400159f - 0.85373472095314f * (a0 * a0 + h0 * h0);
        m1 *= 1.79284291400159f - 0.85373472095314f * (a1 * a1 + h1 * h1);
        m2 *= 1.79284291400159f - 0.85373472095314f * (a2 * a2 + h2 * h2);
        float g0 = a0 * x0x + h0 * x0y, g1 = a1 * x12x + h1 * x12y, g2 = a2 * x12z + h2 * x12w;
        return 130f * (m0 * g0 + m1 * g1 + m2 * g2);
    }

    static float ColorChanges(float c1, float c2, float stripe, float w0, float w1, float w2, float blur, float bump)
    {
        float ch = Mix(c2, c1, Smooth(0, 2 * blur, stripe));
        float border = w0;
        ch = Mix(ch, c2, Smooth(border, border + 2 * blur, stripe));
        bump = Smooth(0.2f, 0.8f, bump);
        border = w0 + 0.4f * (1 - bump) * w1;
        ch = Mix(ch, c1, Smooth(border, border + 2 * blur, stripe));
        border = w0 + 0.5f * (1 - bump) * w1;
        ch = Mix(ch, c2, Smooth(border, border + 2 * blur, stripe));
        border = w0 + w1;
        ch = Mix(ch, c1, Smooth(border, border + 2 * blur, stripe));
        float gt = (stripe - w0 - w1) / w2;
        float gradient = Mix(c1, c2, Smooth(0, 1, gt));
        ch = Mix(ch, gradient, Smooth(border, border + 0.5f * blur, stripe));
        return ch;
    }

    void Render()
    {
        EnsureBuffers();
        int n = px;
        float t = 0.3f * ((float)time + 2.8f);
        const float repetition = 1.99f, shiftRed = 0.3f, shiftBlue = 0.3f, distortion = 0.07f, contourP = 0.54f, angleP = 70, designRes = 320;
        float softness = 0.05f * 0.1f;
        float[] tint = current[0], tint2 = current[1], tint3 = current[2];
        float texel = 6f / ShapeSize; // rayon du flou de bord : 6 texels de la forme d'origine

        Parallel.For(0, n, y =>
        {
            for (int x = 0; x < n; x++)
            {
                int i = y * n + x;
                float u = (x + 0.5f) / n, v = (y + 0.5f) / n;
                float imgR = Sample(mipR, u, v), opacity = Sample(mipG, u, v);

                float ru = u - 0.5f, rv = v - 0.5f;
                float ang = (-angleP + 70f) * PI / 180f;
                float ca = MathF.Cos(ang), sa = MathF.Sin(ang);
                float rux = ru * ca - rv * sa + 0.5f, ruy = ru * sa + rv * ca + 0.5f;

                float sum = 4 * imgR
                    + 2 * Sample(mipR, u, v - texel) + 2 * Sample(mipR, u, v + texel)
                    + 2 * Sample(mipR, u - texel, v) + 2 * Sample(mipR, u + texel, v)
                    + Sample(mipR, u - texel, v - texel) + Sample(mipR, u + texel, v - texel)
                    + Sample(mipR, u - texel, v + texel) + Sample(mipR, u + texel, v + texel);
                float edge = MathF.Pow(sum / 16f, 1.6f);
                edge *= Smooth(0, 0.4f, contourP);

                float diagBL = rux - ruy, diagTL = rux + ruy;

                float gx = u - 0.5f, gy = v - 0.5f;
                float dist = MathF.Sqrt(gx * gx + (gy + 0.2f * diagBL) * (gy + 0.2f * diagBL));
                float th = (0.25f - 0.2f * diagBL) * PI;
                // rotate2 Metal : matrice colonnes (cos, sin), (-sin, cos)
                float direction = MathF.Cos(th) * gx - MathF.Sin(th) * gy;

                float bump = 1 - MathF.Pow(1.8f * dist, 1.2f);
                bump *= MathF.Pow(v, 0.3f);

                float thin1 = 0.12f / repetition * (1 - 0.4f * bump);
                float thin2 = 0.07f / repetition * (1 + 0.4f * bump);
                float wide = 1 - thin1 - thin2;

                float noise = SNoise(u - t, v - t);
                edge += (1 - edge) * distortion * noise;

                direction += diagBL;
                float se = Smooth(0, 1, edge);
                direction -= 2 * noise * diagBL * (se * (1 - se));
                direction *= Mix(1, 1 - edge, Smooth(0.5f, 1, contourP));
                direction -= 1.7f * edge * Smooth(0.5f, 1, contourP);
                direction += 0.2f * MathF.Pow(contourP, 4) * (1 - se);

                bump *= Math.Clamp(MathF.Pow(v, 0.1f), 0.3f, 1f);
                direction *= 0.1f + (1.1f - edge) * bump;
                direction *= 0.4f + 0.6f * (1 - Smooth(0.5f, 1, edge));
                direction += 0.18f * (Smooth(0.1f, 0.2f, v) * (1 - Smooth(0.2f, 0.4f, v)));
                direction += 0.03f * (Smooth(0.1f, 0.2f, 1 - v) * (1 - Smooth(0.2f, 0.4f, 1 - v)));
                direction *= 0.5f + 0.5f * v * v;
                direction *= repetition;
                direction -= t;

                // Palette de la pochette : dominante et accent suivent les bandes, 2e accent en reflet diagonal.
                float flow = 0.5f + 0.5f * MathF.Sin((direction * 0.5f + 0.35f * noise) * 2 * PI);
                float cov2 = tint2[3];
                float k2 = (cov2 > 0.001f ? 1 : 0) * Smooth(1 - cov2 - 0.12f, 1 - cov2 + 0.12f, flow);
                float tr = Mix(tint[0], tint2[0], k2), tg = Mix(tint[1], tint2[1], k2), tb = Mix(tint[2], tint2[2], k2);
                float sweep = 0.5f + 0.5f * MathF.Sin((u - v) * 4 + t * 1.7f + 2 * noise);
                float k3 = MathF.Min(1, tint3[3] * 2.5f) * 0.85f * Smooth(0.6f, 0.95f, sweep);
                tr = Mix(tr, tint3[0], k3); tg = Mix(tg, tint3[1], k3); tb = Mix(tb, tint3[2], k3);

                float disp = Clamp01(1 - bump);
                float dRed = disp + 0.03f * bump * noise
                    + 5 * (Smooth(-0.1f, 0.2f, v) * (1 - Smooth(0.1f, 0.5f, v))) * (Smooth(0.4f, 0.6f, bump) * (1 - Smooth(0.4f, 1, bump)))
                    - diagBL;
                float dBlue = disp * 1.3f
                    + (Smooth(0, 0.4f, v) * (1 - Smooth(0.1f, 0.8f, v))) * (Smooth(0.4f, 0.6f, bump) * (1 - Smooth(0.4f, 0.8f, bump)))
                    - 0.2f * edge;
                dRed *= shiftRed / 20f;
                dBlue *= shiftBlue / 20f;

                float blur = softness + 0.5f * Smooth(1, 10, repetition) * se;
                float smallCanvas = 1 - Smooth(100, 500, designRes);
                blur += smallCanvas * se;
                float rExtra = softness * (0.05f + 0.1f * (shiftRed / 20f) * bump);
                float gExtra = softness * 0.05f / MathF.Max(0.001f, MathF.Abs(1 - diagBL));

                float w1 = repetition * thin2 - 0.02f * Smooth(0, 1, edge + bump);
                sR[i] = Fract(direction + dRed);
                sG[i] = Fract(direction);
                sB[i] = Fract(direction - dBlue);
                pBlur[i] = blur; pRx[i] = rExtra; pGx[i] = gExtra; pBump[i] = bump;
                pW0[i] = repetition * thin1; pW1[i] = w1; pW2[i] = wide;
                pTc[i * 3] = tr; pTc[i * 3 + 1] = tg; pTc[i * 3 + 2] = tb;
                pOp[i] = opacity;
            }
        });

        float strength = tint[3];
        Parallel.For(0, n, y =>
        {
            int qy = y & ~1;
            for (int x = 0; x < n; x++)
            {
                int i = y * n + x;
                int qx = x & ~1;
                // fwidth par blocs 2×2, comme les dérivées du GPU.
                float Fw(float[] s)
                {
                    int a = qy * n + qx, bx = qy * n + Math.Min(qx + 1, n - 1), by = Math.Min(qy + 1, n - 1) * n + qx;
                    return MathF.Abs(s[bx] - s[a]) + MathF.Abs(s[by] - s[a]);
                }
                float blur = pBlur[i], bump = pBump[i];
                float r = ColorChanges(0.98f, 0.1f, sR[i], pW0[i], pW1[i], pW2[i], blur + Fw(sR) + pRx[i], bump);
                float g = ColorChanges(0.98f, 0.1f, sG[i], pW0[i], pW1[i], pW2[i], blur + Fw(sG) + pGx[i], bump);
                // color2.b dépend de la diagonale (0.1 + 0.1 * smoothstep(0.7, 1.3, diagTLtoBR)) : recalculée ici.
                float u = (x + 0.5f) / n, v = (y + 0.5f) / n;
                float diagTL = (u - 0.5f) + 0.5f + (v - 0.5f) + 0.5f;
                float c2b = 0.1f + 0.1f * Smooth(0.7f, 1.3f, diagTL);
                float b = ColorChanges(1f, c2b, sB[i], pW0[i], pW1[i], pW2[i], blur + Fw(sB), bump);

                // Teinte en « incrustation » : garde la vraie nuance de la pochette.
                float o = pOp[i];
                float Ch(float bse, float tc)
                {
                    bse = Clamp01(bse);
                    float sh = MathF.Pow(bse, 1.7f);
                    float ov = sh < 0.5f ? 2 * sh * tc : 1 - 2 * (1 - sh) * (1 - tc);
                    float c = Clamp01(Mix(bse, ov, strength));
                    if (float.IsNaN(c)) c = 0.5f;
                    return c;
                }
                float cr = Ch(r, pTc[i * 3]), cg = Ch(g, pTc[i * 3 + 1]), cb = Ch(b, pTc[i * 3 + 2]);
                if (float.IsNaN(o)) o = 0;
                float dither = 1f / 256f * (Fract(MathF.Sin(0.014f * (x + 0.5f) * 12.9898f + 0.014f * (y + 0.5f) * 78.233f) * 43758.5453123f) - 0.5f);
                cr = cr * o + dither; cg = cg * o + dither; cb = cb * o + dither;
                // Pbgra32 : couleurs prémultipliées.
                pixels[i * 4] = (byte)Math.Clamp(cb * 255 + 0.5f, 0, o * 255);
                pixels[i * 4 + 1] = (byte)Math.Clamp(cg * 255 + 0.5f, 0, o * 255);
                pixels[i * 4 + 2] = (byte)Math.Clamp(cr * 255 + 0.5f, 0, o * 255);
                pixels[i * 4 + 3] = (byte)Math.Clamp(o * 255 + 0.5f, 0, 255);
            }
        });
        Frame!.WritePixels(new Int32Rect(0, 0, n, n), pixels, n * 4, 0);
    }
}
