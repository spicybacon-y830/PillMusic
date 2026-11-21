using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace PillMusic;

/// Icônes dessinées à la main (mêmes formes que la version Mac).
static class Glyphs
{
    /// Polygone aux coins arrondis (équivalent de addArc(tangent1End:tangent2End:radius:)).
    public static Geometry RoundedPolygon(IList<Point> pts, double radius)
    {
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            int n = pts.Count;
            for (int i = 0; i < n; i++)
            {
                Point prev = pts[(i + n - 1) % n], p = pts[i], next = pts[(i + 1) % n];
                Vector a = prev - p, b = next - p;
                double la = a.Length, lb = b.Length;
                a /= la; b /= lb;
                double angle = Math.Acos(Math.Clamp(a.X * b.X + a.Y * b.Y, -1, 1));
                double d = Math.Min(radius / Math.Tan(angle / 2), Math.Min(la, lb) / 2);
                double r = d * Math.Tan(angle / 2);
                Point start = p + a * d, end = p + b * d;
                if (i == 0) ctx.BeginFigure(start, true, true); else ctx.LineTo(start, true, true);
                bool clockwise = a.X * b.Y - a.Y * b.X < 0;
                ctx.ArcTo(end, new Size(r, r), 0, false, clockwise ? SweepDirection.Clockwise : SweepDirection.Counterclockwise, true, true);
            }
        }
        g.Freeze();
        return g;
    }

    /// Triangle arrondi du design (SVG viewBox 78×78).
    public static Geometry Play(Rect r)
    {
        double k = r.Width / 78;
        Point P(double x, double y) => new(r.X + x * k, r.Y + y * k);
        return RoundedPolygon(new[] { P(16.54, 4.93), P(74.2, 39), P(16.54, 73.07) }, 6.6 * k);
    }

    public static Geometry Pause(Rect r)
    {
        double k = r.Width / 78;
        var g = new GeometryGroup();
        g.Children.Add(new RectangleGeometry(new Rect(r.X + 16.25 * k, r.Y + 9.75 * k, 16.25 * k, 58.5 * k), k, k));
        g.Children.Add(new RectangleGeometry(new Rect(r.X + 45.5 * k, r.Y + 9.75 * k, 16.25 * k, 58.5 * k), k, k));
        g.Freeze();
        return g;
    }

    /// Deux triangles accolés (backward.fill / forward.fill), centrés sur `c`, hauteur `h`.
    public static Geometry Skip(Point c, double h, bool forward)
    {
        double w = h * 0.86;
        double rr = h * 0.12;
        var g = new GeometryGroup { FillRule = FillRule.Nonzero };
        for (int k = 0; k < 2; k++)
        {
            double x0 = c.X - w + k * w;
            var pts = forward
                ? new[] { new Point(x0, c.Y - h / 2), new Point(x0 + w, c.Y), new Point(x0, c.Y + h / 2) }
                : new[] { new Point(x0 + w, c.Y - h / 2), new Point(x0, c.Y), new Point(x0 + w, c.Y + h / 2) };
            g.Children.Add(RoundedPolygon(pts, rr));
        }
        g.Freeze();
        return g;
    }

    /// Bulle de citation (quote.bubble), pleine ou en contour, centrée sur `c`, largeur `w`.
    public static (Geometry shape, Geometry? stroke) QuoteBubble(Point c, double w, bool filled)
    {
        double h = w * 0.78;
        var body = new Rect(c.X - w / 2, c.Y - h / 2, w, h * 0.84);
        var bubble = new RectangleGeometry(body, h * 0.3, h * 0.3);
        // Queue en bas à gauche.
        var tail = RoundedPolygon(new[]
        {
            new Point(body.Left + w * 0.2, body.Bottom - h * 0.1),
            new Point(body.Left + w * 0.42, body.Bottom - h * 0.1),
            new Point(body.Left + w * 0.16, body.Bottom + h * 0.2),
        }, w * 0.03);
        var outline = new CombinedGeometry(GeometryCombineMode.Union, bubble, tail);

        // Deux guillemets : un rond et une petite virgule.
        var quotes = new GeometryGroup();
        double qr = w * 0.095, qy = body.Top + body.Height * 0.46;
        foreach (var qx in new[] { c.X - w * 0.15, c.X + w * 0.13 })
        {
            quotes.Children.Add(new EllipseGeometry(new Point(qx, qy), qr, qr));
            quotes.Children.Add(RoundedPolygon(new[]
            {
                new Point(qx + qr * 0.1, qy), new Point(qx + qr, qy + qr * 0.2), new Point(qx - qr * 0.6, qy + qr * 2.3),
            }, qr * 0.2));
        }

        if (filled)
        {
            var g = new CombinedGeometry(GeometryCombineMode.Exclude, outline, quotes);
            g.Freeze();
            return (g, null);
        }
        outline.Freeze();
        quotes.Freeze();
        return (quotes, outline);
    }
}
