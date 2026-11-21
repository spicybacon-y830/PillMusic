using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PillMusic;

/// Couleurs dérivées de la pochette pour teinter le shader du bouton (portage fidèle de la version Mac).
sealed record PaletteColors(Color[] Tints, float[] Coverage, float Strength, Color Disc)
{
    public static readonly PaletteColors Fallback = new(new[] { Design.Hex(0xCA0503) }, new[] { 0f, 0f }, 1, Design.Hex(0xC11F42));
    /// Pochette noir et blanc : métal argenté.
    public static readonly PaletteColors Neutral = new(new[] { Color.FromRgb(219, 222, 230) }, new[] { 0f, 0f }, 1, Color.FromRgb(115, 117, 128));
}

static class Palette
{
    record struct Swatch(double Hue, double Sat, double Val, double Share);

    public static PaletteColors? Extract(BitmapSource image)
    {
        const int W = 64, H = 64;
        byte[] px;
        try
        {
            var scaled = new TransformedBitmap(image, new ScaleTransform((double)W / image.PixelWidth, (double)H / image.PixelHeight));
            var conv = new FormatConvertedBitmap(scaled, PixelFormats.Pbgra32, null, 0);
            int w = conv.PixelWidth, h = conv.PixelHeight;
            px = new byte[w * h * 4];
            conv.CopyPixels(px, w * 4, 0);
        }
        catch { return null; }

        const int bins = 36;
        var weight = new double[bins];
        var sums = new (double r, double g, double b)[bins];
        int chromatic = 0, total = px.Length / 4;

        for (int i = 0; i < px.Length; i += 4)
        {
            double b = px[i] / 255.0, g = px[i + 1] / 255.0, r = px[i + 2] / 255.0;
            var (hue, s, v) = Hsv(r, g, b);
            // Blancs, gris et noirs : neutres (ils rendent le métal plus argenté, pas coloré).
            if (!(v > 0.14 && s > 0.1)) continue;
            chromatic++;
            double wgt = 0.3 + s;
            if (v < 0.3) wgt *= v / 0.3;
            int bin = Math.Min((int)(hue * bins), bins - 1);
            weight[bin] += wgt;
            sums[bin].r += r * wgt; sums[bin].g += g * wgt; sums[bin].b += b * wgt;
        }
        double chromaFraction = (double)chromatic / total;
        if (chromaFraction <= 0.04) return PaletteColors.Neutral;

        var smooth = Enumerable.Range(0, bins)
            .Select(i => weight[(i + bins - 1) % bins] * 0.5 + weight[i] + weight[(i + 1) % bins] * 0.5).ToArray();
        var order = Enumerable.Range(0, bins).OrderByDescending(i => smooth[i]).ToList();
        var picked = new List<int>();
        foreach (var i in order)
        {
            if (picked.Count == 3) break;
            // Un accent doit couvrir au moins 12 % de la surface de la couleur dominante.
            if (picked.Count > 0 && smooth[i] < smooth[picked[0]] * 0.12) break;
            if (picked.All(p => { int d = Math.Abs(p - i); return Math.Min(d, bins - d) >= 5; })) picked.Add(i);
        }

        var swatches = new List<Swatch>();
        foreach (var bin in picked)
        {
            double r = 0, g = 0, b = 0, ws = 0;
            foreach (var j in new[] { -1, 0, 1 })
            {
                int k = (bin + j + bins) % bins;
                r += sums[k].r; g += sums[k].g; b += sums[k].b; ws += weight[k];
            }
            if (ws <= 0) continue;
            var (h, s, v) = Hsv(r / ws, g / ws, b / ws);
            swatches.Add(new Swatch(h, s, v, smooth[bin] / smooth[picked[0]]));
        }
        if (swatches.Count == 0) return PaletteColors.Neutral;

        // Teinte fidèle : vraie nuance, saturation seulement renforcée pour rester visible sur le métal.
        static Color Metal(Swatch s) => FromHsv(s.Hue, Math.Clamp(s.Sat * 1.5, 0.28, 0.95), Math.Clamp(s.Val * 1.15, 0.72, 0.95));

        var main = swatches[0];
        var tints = new List<Color> { Metal(main) };
        var coverage = new List<float>();
        for (int i = 1; i < swatches.Count; i++)
        {
            tints.Add(Metal(swatches[i]));
            coverage.Add((float)Math.Min(swatches[i].Share, 1) * (i == 1 ? 0.5f : 0.4f));
        }
        while (coverage.Count < 2) coverage.Add(0);

        var disc = FromHsv(main.Hue, Math.Clamp(main.Sat * 1.3, 0.25, 0.85), Math.Clamp(main.Val * 0.95, 0.5, 0.8));
        float strength = (float)Math.Clamp(0.5 + chromaFraction, 0.6, 1);
        return new PaletteColors(tints.ToArray(), coverage.ToArray(), strength, disc);
    }

    static (double, double, double) Hsv(double r, double g, double b)
    {
        double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b)), d = mx - mn, h = 0;
        if (d > 0)
        {
            if (mx == r) h = ((g - b) / d) % 6;
            else if (mx == g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h /= 6;
            if (h < 0) h += 1;
        }
        return (h, mx == 0 ? 0 : d / mx, mx);
    }

    public static Color FromHsv(double h, double s, double v)
    {
        h = (h % 1 + 1) % 1 * 6;
        int i = (int)Math.Floor(h);
        double f = h - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
        var (r, g, b) = i switch { 0 => (v, t, p), 1 => (q, v, p), 2 => (p, v, t), 3 => (p, q, v), 4 => (t, p, v), _ => (v, p, q) };
        return Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    }
}
