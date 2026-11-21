using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace PillMusic;

/// Valeurs exactes du design Paper, en unités de design (multipliées par l'échelle de la pilule).
static class Design
{
    public const double Width = 777;
    public const double PaddingH = 24;
    public const double PaddingV = 24;
    public const double Disc = 160;
    public const double Gap = 16;
    public const double Skip = 84;
    public static double Height => Disc + PaddingV * 2;
    public static double SkipExtra => (Skip + Gap) * 3;
    public static double InfoWidth => Width - PaddingH * 2 - Disc * 2 - Gap * 2;

    /// Marges de la fenêtre autour de la pilule (ombre, ouverture, étirement).
    public const double MarginX = 48;
    public const double MarginY = 24;
    public const double EdgeInset = 8;

    public record Palette(Color Bg, Color Title, Color Secondary, Color Track, Color Fill);

    public static Palette Colors(bool dark) => dark
        ? new(Hex(0x1A1A1A), Hex(0xFFFFFF), Hex(0xB4B4B4), Hex(0x3F3F3F), Hex(0x979797))
        : new(Hex(0xFFFFFF), Hex(0x5C5C5C), Hex(0x8C8C8C), Hex(0xE5E5E5), Hex(0x979797));

    public static Color Hex(uint v, byte a = 255) => Color.FromArgb(a, (byte)(v >> 16), (byte)(v >> 8), (byte)v);
    public static Color WithAlpha(Color c, double a) => Color.FromArgb((byte)Math.Clamp(a * 255, 0, 255), c.R, c.G, c.B);

    static Typeface? _font;
    /// Geist Medium (embarquée), sinon Segoe UI.
    public static Typeface Font => _font ??= new Typeface(
        new FontFamily(new Uri("pack://application:,,,/"), "./Assets/#Geist Medium, ./Assets/#Geist, Segoe UI Variable Text, Segoe UI"),
        FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);

    public static readonly Typeface Symbols = new(new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets, Segoe UI Symbol"),
        FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);

    static readonly Dictionary<(string, double, uint, bool), FormattedText> textCache = new();

    /// Texte mis en cache (évite de reformater à chaque image d'animation).
    public static FormattedText Text(string s, double size, Color color, double dpi, bool symbol = false)
    {
        var key = (s, Math.Round(size, 2), (uint)(color.A << 24 | color.R << 16 | color.G << 8 | color.B), symbol);
        if (textCache.TryGetValue(key, out var t)) return t;
        if (textCache.Count > 400) textCache.Clear();
        var brush = new SolidColorBrush(color); brush.Freeze();
        t = new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, symbol ? Symbols : Font, size, brush, dpi);
        textCache[key] = t;
        return t;
    }

    public static double Lerp(double a, double b, double t) => a + (b - a) * t;
    public static double Clamp01(double v) => Math.Clamp(v, 0, 1);
}

/// Ressort façon SwiftUI : `response` (s) et `dampingFraction`.
sealed class Spring
{
    public double Value;
    public double Velocity;
    public double Target;
    double stiffness, damping;

    public Spring(double value, double response, double dampingFraction)
    {
        Value = Target = value;
        Configure(response, dampingFraction);
    }

    public void Configure(double response, double dampingFraction)
    {
        stiffness = Math.Pow(2 * Math.PI / response, 2);
        damping = 4 * Math.PI * dampingFraction / response;
    }

    public void Snap(double v) { Value = Target = v; Velocity = 0; }

    public bool Moving => Math.Abs(Value - Target) > 0.0005 || Math.Abs(Velocity) > 0.001;

    /// Avance la simulation ; renvoie vrai tant que le ressort bouge.
    public bool Step(double dt)
    {
        if (!Moving) { Value = Target; Velocity = 0; return false; }
        const double h = 1.0 / 480;
        for (double t = 0; t < dt; t += h)
        {
            double step = Math.Min(h, dt - t);
            double a = -stiffness * (Value - Target) - damping * Velocity;
            Velocity += a * step;
            Value += Velocity * step;
        }
        return true;
    }
}

/// Transition linéaire (ou ease-in) d'une valeur sur une durée fixe.
sealed class Tween
{
    public double Value;
    double from, to, elapsed, duration, delay;
    bool easeIn;

    public Tween(double v) { Value = from = to = v; }
    public double Target => to;

    public void Set(double target, double duration, double delay = 0, bool easeIn = false)
    {
        if (Math.Abs(target - to) < 1e-9 && elapsed < this.duration + this.delay) return;
        from = Value; to = target; elapsed = 0; this.duration = Math.Max(duration, 1e-4); this.delay = delay; this.easeIn = easeIn;
    }

    public void Snap(double v) { Value = from = to = v; elapsed = duration = 1; delay = 0; }

    public bool Step(double dt)
    {
        if (Value == to) return false;
        elapsed += dt;
        double t = Design.Clamp01((elapsed - delay) / duration);
        if (easeIn) t = t * t * t;
        Value = Design.Lerp(from, to, t);
        if (t >= 1) Value = to;
        return true;
    }
}
