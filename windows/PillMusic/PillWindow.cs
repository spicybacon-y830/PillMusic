using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace PillMusic;

enum Zone { None, Pill, Artwork, Play, Bar, Prev, Next, Lyrics }
enum LinkStatus { Loading, Copied, Failed }

/// Fenêtre flottante transparente, toujours au premier plan, qui ne prend jamais le focus.
sealed class PillWindow : Window
{
    public readonly PillView View;
    readonly Border shadow;
    readonly Settings settings;
    public event Action? Moved;
    public event Action<int>? HotKey;
    public event Action<double>? HorizontalWheel;

    public PillWindow(Settings settings, MediaController media, LiquidMetal metal, LyricsModel lyrics)
    {
        this.settings = settings;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Title = "PillMusic";
        Focusable = false;
        UseLayoutRounding = true;

        shadow = new Border { IsHitTestVisible = false };
        View = new PillView(this, settings, media, metal, lyrics);
        var root = new Canvas();
        root.Children.Add(shadow);
        root.Children.Add(View);
        Content = root;
        View.ShadowElement = shadow;
        ApplySize();

        SourceInitialized += (_, _) =>
        {
            Native.MakeToolWindow(this);
            var src = (HwndSource)PresentationSource.FromVisual(this);
            src.AddHook(WndProc);
        };
        DpiChanged += (_, _) => View.OnDpiChanged();
    }

    public void ApplySize()
    {
        double s = settings.Scale;
        Width = (Design.Width + Design.SkipExtra) * s + Design.MarginX * 2;
        Height = Design.Height * s + Design.MarginY * 2;
        View.Width = Width;
        View.Height = Height;
        View.OnDpiChanged();
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_MOUSEACTIVATE:
                handled = true;
                return new IntPtr(Native.MA_NOACTIVATE);
            case Native.WM_MOUSEHWHEEL:
                HorizontalWheel?.Invoke((short)((wParam.ToInt64() >> 16) & 0xFFFF));
                handled = true;
                break;
            case Native.WM_HOTKEY:
                HotKey?.Invoke(wParam.ToInt32());
                handled = true;
                break;
        }
        return IntPtr.Zero;
    }

    public void NotifyMoved() => Moved?.Invoke();
}

/// Toute la pilule, dessinée à la main avec des ressorts façon SwiftUI.
sealed class PillView : FrameworkElement
{
    readonly PillWindow window;
    readonly Settings settings;
    readonly MediaController media;
    readonly LiquidMetal metal;
    readonly LyricsModel lyrics;
    public Border? ShadowElement;

    public Action? OnArtworkClick, OnArtworkDoubleClick, OnRightClick;
    public LinkStatus? Link;
    readonly Tween linkFade = new(0);

    // Animations (mêmes réglages que la version Mac).
    readonly Spring expand = new(0, 0.5, 0.5);
    readonly Spring edgeShift = new(0, 0.5, 0.5);
    readonly Spring shown = new(0, 0.5, 0.58);
    readonly Spring squashX = new(1, 0.18, 0.7), squashY = new(1, 0.18, 0.7);
    readonly Spring lift = new(1, 0.3, 0.5);
    readonly Spring shadowLift = new(0, 0.3, 0.5);
    readonly Spring nudge = new(0, 0.15, 0.85);
    readonly Spring textSwap = new(1, 0.5, 0.78);
    readonly Spring artSwap = new(1, 0.55, 0.6);
    readonly Tween artOld = new(0);
    readonly Spring barActive = new(0, 0.28, 0.5);
    readonly Spring playScale = new(1, 0.3, 0.45);
    readonly Spring wobbleX = new(1, 0.35, 0.3), wobbleY = new(1, 0.35, 0.3);
    readonly Spring[] skipPress = { new(1, 0.3, 0.75), new(1, 0.3, 0.75), new(1, 0.3, 0.75) };
    readonly Tween[] skipHover = { new(0), new(0), new(0) };
    readonly Tween lyricsActive = new(0);
    readonly Tween discR = new(0xC1), discG = new(0x1F), discB = new(0x42);
    readonly Tween winX = new(0), winY = new(0);
    bool animatingWindow;
    readonly List<Spring> springs = new();
    readonly List<Tween> tweens = new();

    public bool Expanded { get; private set; }
    public bool Shown { get; private set; }
    Point? pointer;
    bool canExpand;
    double S => settings.Scale;
    double dpi = 1;

    // Glisser / clic
    Zone pressedZone = Zone.None;
    Point dragCursorStart; // pixels
    Point dragWindowStart;
    bool dragging;
    Point lastCursor; DateTime lastMoveTime;
    double? scrub;
    readonly DispatcherTimer artworkClickTimer;

    // Titre : ancien texte qui part pendant que le nouveau arrive.
    string curKey = "", curTitle = "", curArtist = "";
    string oldTitle = "", oldArtist = "";
    double swapDir = 1;
    public double SkipDirection = 1;
    string? curArtId; BitmapSource? curArt, oldArt;
    double artDir = 1;

    // Défilement des titres longs
    double marqueeClock;
    DateTime lastRender = DateTime.UtcNow;
    readonly Dictionary<string, double> marqueeStart = new();

    // Swipe horizontal (pavé tactile / molette inclinable)
    double scrollAccum;
    bool scrollFired;
    readonly DispatcherTimer scrollEnd;

    bool rendering;
    DateTime lastTick;

    public PillView(PillWindow window, Settings settings, MediaController media, LiquidMetal metal, LyricsModel lyrics)
    {
        this.window = window; this.settings = settings; this.media = media; this.metal = metal; this.lyrics = lyrics;
        springs.AddRange(new[] { expand, edgeShift, shown, squashX, squashY, lift, shadowLift, nudge, textSwap, artSwap, barActive, playScale, wobbleX, wobbleY });
        springs.AddRange(skipPress);
        tweens.AddRange(new[] { linkFade, artOld, lyricsActive, discR, discG, discB, winX, winY });
        tweens.AddRange(skipHover);

        artworkClickTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(System.Windows.Forms.SystemInformation.DoubleClickTime) };
        artworkClickTimer.Tick += (_, _) => { artworkClickTimer.Stop(); OnArtworkClick?.Invoke(); };
        scrollEnd = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(220) };
        scrollEnd.Tick += (_, _) => { scrollEnd.Stop(); scrollAccum = 0; scrollFired = false; Animate(nudge, 0, 0.45, 0.8); };

        metal.FrameReady += InvalidateVisual;
        media.Changed += OnMediaChanged;
        window.HorizontalWheel += OnHorizontalWheel;
        lyricsActive.Snap(lyrics.Enabled ? 1 : 0);
        OnMediaChanged();
    }

    public void OnDpiChanged()
    {
        dpi = Native.DpiScale(this);
        metal.Pixels = (int)Math.Round(Design.Disc * S * dpi);
        InvalidateVisual();
    }

    // MARK: Boucle d'animation

    void Kick()
    {
        if (rendering) return;
        rendering = true;
        lastTick = DateTime.UtcNow;
        CompositionTarget.Rendering += OnFrame;
    }

    void OnFrame(object? sender, EventArgs e)
    {
        var now = DateTime.UtcNow;
        double dt = Math.Min((now - lastTick).TotalSeconds, 0.05);
        lastTick = now;
        bool active = false;
        foreach (var s in springs) active |= s.Step(dt);
        foreach (var t in tweens) active |= t.Step(dt);
        if (animatingWindow)
        {
            window.Left = winX.Value; window.Top = winY.Value;
            if (winX.Value == winX.Target && winY.Value == winY.Target) { animatingWindow = false; window.NotifyMoved(); }
            else window.NotifyMoved();
        }
        InvalidateVisual();
        UpdateShadow();
        if (!active)
        {
            CompositionTarget.Rendering -= OnFrame;
            rendering = false;
            if (!Shown && window.IsVisible) window.Hide();
        }
    }

    void Animate(Spring s, double target, double response, double damping)
    {
        s.Configure(response, damping);
        s.Target = target;
        Kick();
    }

    void AnimateTween(Tween t, double target, double duration, double delay = 0, bool easeIn = false)
    {
        t.Set(target, duration, delay, easeIn);
        Kick();
    }

    /// Rendu de test : état figé, sans animation.
    public void RenderDemo(bool expanded)
    {
        Shown = true; shown.Snap(1);
        Expanded = expanded; expand.Snap(expanded ? 1 : 0);
        canExpand = true;
        OnMediaChanged();
        textSwap.Snap(1); artSwap.Snap(1); artOld.Snap(0);
        lyricsActive.Snap(lyrics.Enabled ? 1 : 0);
        var d = media.Palette.Disc;
        discR.Snap(d.R); discG.Snap(d.G); discB.Snap(d.B);
        UpdateShadow();
    }

    // MARK: Apparition

    public void SetShown(bool visible)
    {
        if (visible == Shown && (visible ? window.IsVisible : true)) return;
        Shown = visible;
        if (visible)
        {
            if (!window.IsVisible) window.Show();
            Animate(shown, 1, 0.5, 0.58);
        }
        else
        {
            Animate(shown, 0, 0.22, 1);
        }
        metal.Visible = visible;
    }

    // MARK: Données

    void OnMediaChanged()
    {
        bool playing = media.State == PlayerState.Playing;
        canExpand = media.Track != null;
        UpdateExpanded();

        // Titre / artiste : transition glissée quand le morceau change.
        var (title, artist) = Texts();
        var key = media.Track?.Id ?? title;
        if (key != curKey)
        {
            if (curKey.Length > 0)
            {
                oldTitle = curTitle; oldArtist = curArtist;
                swapDir = SkipDirection;
                textSwap.Snap(0);
                Animate(textSwap, 1, 0.5, 0.78);
            }
            curKey = key;
            marqueeClock = 0;
        }
        curTitle = title; curArtist = artist;

        // Pochette : la nouvelle arrive en grossissant, l'ancienne s'efface ensuite.
        var artId = media.Artwork == null ? null : media.Artwork.GetHashCode().ToString();
        if (artId != curArtId)
        {
            oldArt = curArt;
            curArt = media.Artwork;
            curArtId = artId;
            artDir = SkipDirection;
            artSwap.Snap(0);
            Animate(artSwap, 1, 0.55, 0.6);
            artOld.Snap(1);
            AnimateTween(artOld, 0, 0.2, 0.3);
        }

        // Couleur du disque et du métal.
        var disc = media.Palette.Disc;
        AnimateTween(discR, disc.R, 0.6); AnimateTween(discG, disc.G, 0.6); AnimateTween(discB, disc.B, 0.6);
        metal.SetPalette(media.Palette);
        metal.TargetSpeed = playing ? (IsHovering(Zone.Play) ? 1.6 : 1) : 0;
        InvalidateVisual();
    }

    (string, string) Texts() => media.State switch
    {
        PlayerState.NotRunning => ("Rien en lecture", "Lance un morceau dans ton lecteur"),
        PlayerState.Stopped => ("Rien en lecture", $"Lance un morceau dans {media.SourceLabel}"),
        _ => (media.Track?.Title ?? "—", media.Track?.Artist ?? ""),
    };

    public void SetLink(LinkStatus? status)
    {
        if (status != null) Link = status;
        AnimateTween(linkFade, status != null ? 1 : 0, status != null ? 0.2 : 0.25);
    }

    public void LyricsToggled() => AnimateTween(lyricsActive, lyrics.Enabled ? 1 : 0, 0.15);

    // MARK: Géométrie

    double WinW => (Design.Width + Design.SkipExtra) * S + Design.MarginX * 2;
    double WinH => Design.Height * S + Design.MarginY * 2;

    Rect PillRect(double e, double shift)
    {
        double w = (Design.Width + Design.SkipExtra * e) * S, h = Design.Height * S;
        return new Rect((WinW - w) / 2 + shift, (WinH - h) / 2, w, h);
    }

    /// Rectangle de la pilule fermée, en coordonnées d'écran (unités WPF).
    public Rect CollapsedScreenRect()
    {
        var r = PillRect(0, 0);
        r.Offset(window.Left, window.Top);
        return r;
    }

    double NeededEdgeShift()
    {
        double w = (Design.Width + Design.SkipExtra) * S;
        double minX = window.Left + (WinW - w) / 2, maxX = minX + w;
        var wa = Native.WorkArea(new Point(window.Left + WinW / 2, window.Top + WinH / 2), dpi);
        if (minX < wa.Left + Design.EdgeInset) return wa.Left + Design.EdgeInset - minX;
        if (maxX > wa.Right - Design.EdgeInset) return wa.Right - Design.EdgeInset - maxX;
        return 0;
    }

    struct Layout
    {
        public Rect Pill;
        public double Cy, D, ArtX, InfoX, InfoW, PlayCx;
        public double[] SkipCx;
        public double SkipSize;
        public Rect Bar, BarZone;
    }

    Layout ComputeLayout()
    {
        var l = new Layout();
        double e = expand.Value;
        l.Pill = PillRect(e, edgeShift.Value);
        l.Cy = l.Pill.Top + l.Pill.Height / 2;
        l.D = Design.Disc * S;
        l.ArtX = l.Pill.Left + Design.PaddingH * S;
        l.InfoX = l.ArtX + l.D + Design.Gap * S;
        l.InfoW = Design.InfoWidth * S;
        double x = l.InfoX + l.InfoW;
        l.SkipSize = Design.Skip * S;
        l.SkipCx = new double[3];
        for (int k = 0; k < 3; k++)
        {
            double slot = (Design.Skip + Design.Gap) * S * e;
            l.SkipCx[k] = x + Design.Gap * S * e + Design.Skip * S * e / 2;
            x += slot;
        }
        l.PlayCx = x + Design.Gap * S + l.D / 2;

        // Barre de progression (pour le survol et le glisser).
        var (top, _, _, _, rowY, rowH) = InfoMetrics(l);
        double tf = Math.Max(16 * S, 8);
        double leftW = TimeWidth(media.Track?.Duration ?? 0, tf), rightW = leftW + Design.Text("-", tf, Colors.Black, dpi).WidthIncludingTrailingWhitespace;
        double innerX = l.InfoX + 32 * S, innerW = l.InfoW - 64 * S;
        double bx = innerX + leftW + 8 * S, bw = Math.Max(0, innerW - leftW - rightW - 16 * S);
        double zoneH = Math.Max(7 * S, 2.5) * 2 + 2;
        l.BarZone = new Rect(bx, rowY + rowH / 2 - zoneH / 2, bw, zoneH);
        l.Bar = l.BarZone;
        _ = top;
        return l;
    }

    (double top, double th, double ah, double gap, double rowY, double rowH) InfoMetrics(Layout l)
    {
        double th = Math.Max(48 * S, 14), ah = Math.Max(24 * S, 11), gap = 27 * S * 0.6;
        double tf = Math.Max(16 * S, 8);
        double rowH = Math.Max(Math.Max(7 * S, 2.5) * 2 + 2, Design.Text("0:00", tf, Colors.Black, dpi).Height);
        double colH = th + 4 * S + ah + gap + rowH;
        double top = l.Cy - colH / 2;
        return (top, th, ah, gap, top + th + 4 * S + ah + gap, rowH);
    }

    double TimeWidth(double duration, double size)
    {
        // Largeur fixe pour éviter que la barre ne bouge pendant la lecture.
        var sample = duration >= 600 ? "00:00" : "0:00";
        return Design.Text(sample, size, Colors.Black, dpi).WidthIncludingTrailingWhitespace;
    }

    Zone HitZone(Point p, Layout l)
    {
        if (!l.Pill.Contains(p)) return Zone.None;
        if (Dist(p, new Point(l.PlayCx, l.Cy)) <= l.D / 2) return Zone.Play;
        if (Dist(p, new Point(l.ArtX + l.D / 2, l.Cy)) <= l.D / 2) return Zone.Artwork;
        if (expand.Value > 0.5)
        {
            var zones = new[] { Zone.Lyrics, Zone.Prev, Zone.Next };
            for (int k = 0; k < 3; k++)
                if (Dist(p, new Point(l.SkipCx[k], l.Cy)) <= l.SkipSize / 2) return zones[k];
        }
        if (l.BarZone.Contains(p) && media.Track != null) return Zone.Bar;
        return Zone.Pill;
    }

    static double Dist(Point a, Point b) => (a - b).Length;

    bool IsHovering(Zone z) => pointer is { } p && HitZone(p, ComputeLayout()) == z;

    void UpdateExpanded()
    {
        if (dragging) return;
        bool open = false;
        if (pointer is { } p && canExpand)
        {
            var r = PillRect(Expanded ? 1 : 0, Expanded ? edgeShift.Target : 0);
            r.Inflate(3, 3);
            open = r.Contains(p);
        }
        if (open != Expanded)
        {
            Expanded = open;
            Animate(expand, open ? 1 : 0, 0.5, 0.5);
            Animate(edgeShift, open ? NeededEdgeShift() : 0, 0.5, 0.5);
        }
    }

    // MARK: Souris

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        pointer = p;
        if (pressedZone != Zone.None && e.LeftButton == MouseButtonState.Pressed) DragMove(p);
        UpdateHover();
        UpdateExpanded();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        if (IsMouseCaptured) return;
        pointer = null;
        UpdateHover();
        UpdateExpanded();
    }

    void UpdateHover()
    {
        var l = ComputeLayout();
        var z = pointer is { } p ? HitZone(p, l) : Zone.None;
        var zones = new[] { Zone.Lyrics, Zone.Prev, Zone.Next };
        for (int k = 0; k < 3; k++) AnimateTween(skipHover[k], z == zones[k] ? 1 : 0, 0.15);
        Animate(barActive, z == Zone.Bar || scrub != null ? 1 : 0, 0.28, 0.5);
        if (pressedZone != Zone.Play) Animate(playScale, z == Zone.Play ? 1.07 : 1, 0.3, 0.45);
        metal.TargetSpeed = media.State == PlayerState.Playing ? (z == Zone.Play ? 1.6 : 1) : 0;
        Cursor = z is Zone.Play or Zone.Prev or Zone.Next or Zone.Lyrics or Zone.Artwork or Zone.Bar ? Cursors.Hand : Cursors.Arrow;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        var p = e.GetPosition(this);
        var l = ComputeLayout();
        var z = HitZone(p, l);
        if (z == Zone.None) return;
        pressedZone = z;
        dragCursorStart = Native.CursorPixels();
        dragWindowStart = new Point(window.Left, window.Top);
        lastCursor = dragCursorStart; lastMoveTime = DateTime.UtcNow;
        CaptureMouse();
        switch (z)
        {
            case Zone.Play: Animate(playScale, 0.84, 0.25, 0.5); break;
            case Zone.Lyrics: Animate(skipPress[0], 0.9, 0.3, 0.75); break;
            case Zone.Prev: Animate(skipPress[1], 0.9, 0.3, 0.75); break;
            case Zone.Next: Animate(skipPress[2], 0.9, 0.3, 0.75); break;
            case Zone.Bar:
                if (media.Track?.Duration > 0) { scrub = Design.Clamp01((p.X - l.Bar.Left) / l.Bar.Width); UpdateHover(); InvalidateVisual(); }
                break;
            case Zone.Artwork:
                if (e.ClickCount >= 2) { artworkClickTimer.Stop(); OnArtworkDoubleClick?.Invoke(); pressedZone = Zone.None; ReleaseMouseCapture(); }
                break;
        }
        e.Handled = true;
    }

    void DragMove(Point p)
    {
        if (pressedZone == Zone.Bar)
        {
            var l = ComputeLayout();
            if (media.Track?.Duration > 0) scrub = Design.Clamp01((p.X - l.Bar.Left) / l.Bar.Width);
            InvalidateVisual();
            return;
        }
        // Les boutons gardent le clic (comme sur Mac) : seuls la pochette et le fond déplacent la pilule.
        if (pressedZone is Zone.Play or Zone.Prev or Zone.Next or Zone.Lyrics) return;
        var cur = Native.CursorPixels();
        double dx = (cur.X - dragCursorStart.X) / dpi, dy = (cur.Y - dragCursorStart.Y) / dpi;
        if (!dragging)
        {
            if (Math.Sqrt(dx * dx + dy * dy) <= 3) return;
            dragging = true;
            artworkClickTimer.Stop();
            Animate(lift, 1.045, 0.3, 0.5);
            Animate(shadowLift, 1, 0.3, 0.5);
        }
        animatingWindow = false;
        window.Left = dragWindowStart.X + dx;
        window.Top = dragWindowStart.Y + dy;
        window.NotifyMoved();

        // Étirement selon la vitesse (squash & stretch).
        var now = DateTime.UtcNow;
        double dt = Math.Max((now - lastMoveTime).TotalSeconds, 1.0 / 240);
        double vx = (cur.X - lastCursor.X) / dpi / dt, vy = (cur.Y - lastCursor.Y) / dpi / dt;
        lastCursor = cur; lastMoveTime = now;
        double sx = Math.Min(Math.Abs(vx) / 4500, 0.09), sy = Math.Min(Math.Abs(vy) / 4500, 0.09);
        Animate(squashX, 1 + sx - sy * 0.5, 0.18, 0.7);
        Animate(squashY, 1 + sy - sx * 0.5, 0.18, 0.7);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        var p = e.GetPosition(this);
        var zone = pressedZone;
        pressedZone = Zone.None;
        ReleaseMouseCapture();
        var l = ComputeLayout();
        bool inside(Zone z) => HitZone(p, l) == z;

        if (dragging)
        {
            dragging = false;
            Animate(lift, 1, 0.3, 0.5);
            Animate(shadowLift, 0, 0.3, 0.5);
            Animate(squashX, 1, 0.45, 0.35);
            Animate(squashY, 1, 0.45, 0.35);
            KeepOnScreen();
            UpdateExpanded();
            var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            t.Tick += (_, _) => { t.Stop(); if (Expanded) Animate(edgeShift, NeededEdgeShift(), 0.5, 0.5); };
            t.Start();
            return;
        }

        switch (zone)
        {
            case Zone.Play:
                Animate(playScale, inside(Zone.Play) ? 1.07 : 1, 0.25, 0.5);
                if (inside(Zone.Play))
                {
                    if (media.State != PlayerState.Playing) metal.Boost(); // élan seulement au lancement
                    Animate(wobbleX, 1.08, 0.35, 0.3); Animate(wobbleY, 0.93, 0.35, 0.3);
                    var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
                    t.Tick += (_, _) => { t.Stop(); Animate(wobbleX, 1, 0.35, 0.3); Animate(wobbleY, 1, 0.35, 0.3); };
                    t.Start();
                    media.PlayPause();
                }
                break;
            case Zone.Lyrics:
                Animate(skipPress[0], 1, 0.3, 0.75);
                if (inside(Zone.Lyrics)) { lyrics.Enabled = !lyrics.Enabled; LyricsToggled(); }
                break;
            case Zone.Prev:
                Animate(skipPress[1], 1, 0.3, 0.75);
                if (inside(Zone.Prev)) { SkipDirection = -1; media.Previous(); }
                break;
            case Zone.Next:
                Animate(skipPress[2], 1, 0.3, 0.75);
                if (inside(Zone.Next)) { SkipDirection = 1; media.Next(); }
                break;
            case Zone.Bar:
                if (scrub is { } s && media.Track != null) media.Seek(s * media.Track.Duration);
                scrub = null;
                UpdateHover();
                break;
            case Zone.Artwork:
                // Simple clic : ouvre le lecteur (après le délai de double-clic).
                if (inside(Zone.Artwork)) { artworkClickTimer.Stop(); artworkClickTimer.Start(); }
                break;
        }
        InvalidateVisual();
    }

    protected override void OnMouseRightButtonUp(MouseButtonEventArgs e)
    {
        if (HitZone(e.GetPosition(this), ComputeLayout()) == Zone.None) return;
        OnRightClick?.Invoke();
        e.Handled = true;
    }

    /// Swipe horizontal : gauche = suivant, droite = précédent ; le titre suit les doigts.
    void OnHorizontalWheel(double delta)
    {
        if (media.Track == null) return;
        scrollEnd.Stop(); scrollEnd.Start();
        double finger = -delta * 0.5;
        scrollAccum += finger;
        double rubber = Math.Sign(scrollAccum) * Math.Min(Math.Abs(scrollAccum) * 0.35, 30);
        Animate(nudge, rubber, 0.15, 0.85);
        if (!scrollFired && Math.Abs(scrollAccum) > 70)
        {
            scrollFired = true;
            bool next = scrollAccum < 0;
            SkipDirection = next ? 1 : -1;
            if (next) media.Next(); else media.Previous();
            Animate(nudge, 0, 0.45, 0.8);
        }
    }

    /// Ramène la pilule dans l'écran si elle a été lâchée trop au bord (elle peut aller dans les coins).
    public void KeepOnScreen(bool animated = true)
    {
        var pill = CollapsedScreenRect();
        var wa = Native.WorkArea(new Point(pill.X + pill.Width / 2, pill.Y + pill.Height / 2), dpi);
        double e = Design.EdgeInset, sx = 0, sy = 0;
        if (pill.Left < wa.Left + e) sx = wa.Left + e - pill.Left;
        if (pill.Right > wa.Right - e) sx = wa.Right - e - pill.Right;
        if (pill.Top < wa.Top + e) sy = wa.Top + e - pill.Top;
        if (pill.Bottom > wa.Bottom - e) sy = wa.Bottom - e - pill.Bottom;
        if (sx == 0 && sy == 0) return;
        if (!animated) { window.Left += sx; window.Top += sy; window.NotifyMoved(); return; }
        winX.Snap(window.Left); winY.Snap(window.Top);
        winX.Set(window.Left + sx, 0.28); winY.Set(window.Top + sy, 0.28);
        animatingWindow = true;
        Kick();
    }

    // MARK: Ombre (élément séparé : jamais recalculée à chaque image du shader)

    void UpdateShadow()
    {
        if (ShadowElement == null) return;
        var l = ComputeLayout();
        var c = Design.Colors(settings.IsDark);
        double lifted = shadowLift.Value;
        ShadowElement.Width = Math.Max(1, l.Pill.Width);
        ShadowElement.Height = l.Pill.Height;
        Canvas.SetLeft(ShadowElement, l.Pill.Left);
        Canvas.SetTop(ShadowElement, l.Pill.Top);
        ShadowElement.CornerRadius = new CornerRadius(l.Pill.Height / 2);
        ShadowElement.Background = new SolidColorBrush(c.Bg);
        double sc = shown.Value;
        ShadowElement.Opacity = Design.Clamp01(sc);
        double scale = Design.Lerp(0.55, 1, sc) * lift.Value;
        ShadowElement.RenderTransform = new ScaleTransform(squashX.Value * scale, squashY.Value * scale, l.Pill.Width / 2, l.Pill.Height / 2);
        if (ShadowElement.Effect is not DropShadowEffect fx)
        {
            fx = new DropShadowEffect { Color = Colors.Black, Direction = 270, RenderingBias = RenderingBias.Performance };
            ShadowElement.Effect = fx;
        }
        bool dark = settings.IsDark;
        fx.Opacity = dark ? 0.45 : Design.Lerp(0.13, 0.22, lifted);
        fx.BlurRadius = Design.Lerp(14, 26, lifted) * S * 2 * 2;
        fx.ShadowDepth = Design.Lerp(6, 14, lifted) * S * 2;
    }

    // MARK: Dessin

    protected override void OnRender(DrawingContext dc)
    {
        var now = DateTime.UtcNow;
        if (media.State == PlayerState.Playing) marqueeClock += Math.Min((now - lastRender).TotalSeconds, 0.1);
        lastRender = now;

        var l = ComputeLayout();
        bool dark = settings.IsDark;
        var c = Design.Colors(dark);
        if (!rendering) UpdateShadow();

        double sc = shown.Value;
        double scale = Design.Lerp(0.55, 1, sc) * lift.Value;
        var center = new Point(l.Pill.Left + l.Pill.Width / 2, l.Cy);
        dc.PushTransform(new ScaleTransform(squashX.Value * scale, squashY.Value * scale, center.X, center.Y));
        dc.PushOpacity(Design.Clamp01(sc));

        // Fond
        var bg = new SolidColorBrush(c.Bg);
        var stroke = new Pen(new SolidColorBrush(dark ? Design.WithAlpha(Colors.White, 0.07) : Design.WithAlpha(Colors.Black, 0.05)), 0.5);
        double r = l.Pill.Height / 2;
        dc.DrawRoundedRectangle(bg, stroke, l.Pill, r, r);
        dc.PushClip(new RectangleGeometry(l.Pill, r, r));

        DrawArtwork(dc, l);
        DrawInfo(dc, l, c);
        DrawButtons(dc, l, c);
        DrawPlay(dc, l);

        dc.Pop(); dc.Pop(); dc.Pop();
    }

    void DrawArtwork(DrawingContext dc, Layout l)
    {
        double d = l.D;
        var center = new Point(l.ArtX + d / 2, l.Cy);
        var clip = new EllipseGeometry(center, d / 2, d / 2);
        dc.PushClip(clip);

        void DrawImage(BitmapSource? img, double scale, double opacity, double dx)
        {
            if (opacity <= 0.001) return;
            var rect = new Rect(center.X - d * scale / 2 + dx, center.Y - d * scale / 2, d * scale, d * scale);
            dc.PushOpacity(opacity);
            if (img != null)
            {
                RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
                dc.DrawImage(img, rect);
            }
            else
            {
                var grad = new LinearGradientBrush(Design.Hex(0xD9D9DE), Design.Hex(0x9C9CA6), new Point(0, 0), new Point(1, 1));
                dc.DrawEllipse(grad, null, new Point(rect.X + rect.Width / 2, rect.Y + rect.Height / 2), rect.Width / 2, rect.Height / 2);
                var note = Design.Text("", d * 0.32 * scale, Design.WithAlpha(Colors.White, 0.9), dpi, symbol: true);
                dc.DrawText(note, new Point(rect.X + (rect.Width - note.Width) / 2, rect.Y + (rect.Height - note.Height) / 2));
            }
            dc.Pop();
        }

        double a = artSwap.Value;
        DrawImage(oldArt, 1, artOld.Value, 0);
        DrawImage(curArt, Design.Lerp(0.6, 1, a), Design.Clamp01(a), (1 - a) * artDir * d * 0.2);

        // Retour du double-clic : lien en recherche, copié, ou introuvable.
        if (linkFade.Value > 0.001 && Link is { } link)
        {
            dc.PushOpacity(linkFade.Value);
            dc.DrawEllipse(new SolidColorBrush(Design.WithAlpha(Colors.Black, 0.45)), null, center, d / 2, d / 2);
            var glyph = link switch { LinkStatus.Loading => "", LinkStatus.Copied => "", _ => "" };
            var t = Design.Text(glyph, d * 0.34, Colors.White, dpi, symbol: true);
            dc.DrawText(t, new Point(center.X - t.Width / 2, center.Y - t.Height / 2));
            dc.Pop();
        }
        dc.Pop();
    }

    void DrawInfo(DrawingContext dc, Layout l, Design.Palette c)
    {
        var (top, th, ah, gap, rowY, rowH) = InfoMetrics(l);
        double innerX = l.InfoX + 32 * S, innerW = l.InfoW - 64 * S;
        dc.PushClip(new RectangleGeometry(new Rect(l.InfoX, l.Pill.Top, l.InfoW, l.Pill.Height)));

        double tf = Math.Max(40 * S, 12), af = Math.Max(20 * S, 9);
        double n = nudge.Value;
        double nudgeOpacity = 1 - Math.Min(Math.Abs(n) / 60, 0.5);
        double t = textSwap.Value;

        void Pair(string title, string artist, double dx, double opacity, string key)
        {
            if (opacity <= 0.001) return;
            dc.PushOpacity(Design.Clamp01(opacity) * nudgeOpacity);
            Marquee(dc, title, tf, c.Title, innerX + dx + n, top, innerW, th, key + "t");
            Marquee(dc, artist, af, c.Secondary, innerX + dx + n, top + th + 4 * S, innerW, ah, key + "a");
            dc.Pop();
        }
        double slide = 40 * S;
        if (t < 1) Pair(oldTitle, oldArtist, -t * swapDir * slide, 1 - t, "old");
        Pair(curTitle, curArtist, (1 - t) * swapDir * slide, t, "cur");

        DrawProgress(dc, l, c, innerX, innerW, rowY, rowH);
        dc.Pop();
    }

    void Marquee(DrawingContext dc, string text, double size, Color color, double x, double y, double w, double lineH, string key)
    {
        var ft = Design.Text(text, size, color, dpi);
        double tw = ft.WidthIncludingTrailingWhitespace;
        double ty = y + (lineH - ft.Height) / 2;
        if (tw <= w + 0.5) { dc.DrawText(ft, new Point(x, ty)); return; }

        const double gap = 36, speed = 26, delay = 2.2;
        double cycle = delay + (tw + gap) / speed;
        double phase = marqueeClock % cycle;
        double offset = phase < delay ? 0 : -(phase - delay) * speed;
        // Fondu gauche seulement quand le texte défile : à l'arrêt, la première lettre reste entière.
        double leftFade = 0.04 * Math.Min(-offset / 12, 1);
        var mask = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0) };
        mask.GradientStops.Add(new GradientStop(leftFade > 0.001 ? Colors.Transparent : Colors.Black, 0));
        mask.GradientStops.Add(new GradientStop(Colors.Black, Math.Max(leftFade, 0.001)));
        mask.GradientStops.Add(new GradientStop(Colors.Black, 0.9));
        mask.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
        var box = new Rect(x, y, w, lineH);
        mask.MappingMode = BrushMappingMode.Absolute;
        mask.StartPoint = new Point(box.Left, 0); mask.EndPoint = new Point(box.Right, 0);
        dc.PushClip(new RectangleGeometry(box));
        dc.PushOpacityMask(mask);
        dc.DrawText(ft, new Point(x + offset, ty));
        dc.DrawText(ft, new Point(x + offset + tw + gap, ty));
        dc.Pop(); dc.Pop();
    }

    void DrawProgress(DrawingContext dc, Layout l, Design.Palette c, double innerX, double innerW, double rowY, double rowH)
    {
        double duration = media.Track?.Duration ?? 0;
        double position = scrub is { } s ? s * duration : media.Position(DateTime.UtcNow);
        double fraction = duration > 0 ? position / duration : 0;
        double tf = Math.Max(16 * S, 8);
        dc.PushOpacity(media.Track == null ? 0.45 : 1);

        var left = Design.Text(Format(position), tf, c.Secondary, dpi);
        var right = Design.Text("-" + Format(Math.Max(duration - position, 0)), tf, c.Secondary, dpi);
        double cy = rowY + rowH / 2;
        dc.DrawText(left, new Point(innerX, cy - left.Height / 2));
        dc.DrawText(right, new Point(innerX + innerW - right.WidthIncludingTrailingWhitespace, cy - right.Height / 2));

        var bar = l.Bar;
        double barH = Math.Max(7 * S, 2.5) * (1 + barActive.Value);
        var track = new Rect(bar.Left, cy - barH / 2, Math.Max(bar.Width, 0), Math.Max(barH, 0.1));
        dc.PushClip(new RectangleGeometry(track, barH / 2, barH / 2));
        dc.DrawRectangle(new SolidColorBrush(c.Track), null, track);
        dc.DrawRectangle(new SolidColorBrush(c.Fill), null, new Rect(track.Left, track.Top, Math.Max(0, track.Width * Design.Clamp01(fraction)), track.Height));
        dc.Pop();
        dc.Pop();
    }

    static string Format(double t)
    {
        int s = (int)Math.Floor(t);
        return $"{s / 60}:{s % 60:00}";
    }

    void DrawButtons(DrawingContext dc, Layout l, Design.Palette c)
    {
        double e = expand.Value;
        if (e <= 0.001) return;
        double size = l.SkipSize;
        for (int k = 0; k < 3; k++)
        {
            var center = new Point(l.SkipCx[k], l.Cy);
            double scale = Design.Lerp(0.01, 1, e) * skipPress[k].Value;
            dc.PushOpacity(Design.Clamp01(e));
            dc.PushTransform(new ScaleTransform(scale, scale, center.X, center.Y));
            double rad = size / 2;
            dc.DrawEllipse(new SolidColorBrush(c.Track), null, center, rad, rad);
            if (skipHover[k].Value > 0.001) dc.DrawEllipse(new SolidColorBrush(Design.WithAlpha(c.Title, 0.12 * skipHover[k].Value)), null, center, rad, rad);
            var fill = new SolidColorBrush(c.Title);
            if (k == 0)
            {
                double act = lyricsActive.Value;
                if (act > 0.001) dc.DrawEllipse(new SolidColorBrush(Design.WithAlpha(c.Title, 0.14 * act)), null, center, rad, rad);
                var (shape, outline) = Glyphs.QuoteBubble(center, size * 0.46 * 1.15, lyrics.Enabled);
                if (outline != null) dc.DrawGeometry(null, new Pen(fill, size * 0.46 * 0.11), outline);
                dc.DrawGeometry(fill, null, shape);
            }
            else
            {
                dc.DrawGeometry(fill, null, Glyphs.Skip(center, size * 0.36 * 0.72, forward: k == 2));
            }
            dc.Pop(); dc.Pop();
        }
    }

    void DrawPlay(DrawingContext dc, Layout l)
    {
        double d = l.D;
        var center = new Point(l.PlayCx, l.Cy);
        double s = playScale.Value;
        dc.PushTransform(new ScaleTransform(s * wobbleX.Value, s * wobbleY.Value, center.X, center.Y));
        var disc = Color.FromRgb((byte)Math.Round(discR.Value), (byte)Math.Round(discG.Value), (byte)Math.Round(discB.Value));
        dc.DrawEllipse(new SolidColorBrush(disc), null, center, d / 2, d / 2);
        if (metal.Frame != null)
        {
            dc.PushClip(new EllipseGeometry(center, d / 2, d / 2));
            dc.DrawImage(metal.Frame, new Rect(center.X - d / 2, center.Y - d / 2, d, d));
            dc.Pop();
        }
        double g = d * 78 / 160;
        var box = new Rect(center.X - g / 2, center.Y - g / 2, g, g);
        bool playing = media.State == PlayerState.Playing;
        var shadowBox = box; shadowBox.Offset(0, d * 0.012);
        var glyphShadow = playing ? Glyphs.Pause(shadowBox) : Glyphs.Play(shadowBox);
        dc.DrawGeometry(new SolidColorBrush(Design.WithAlpha(Colors.Black, 0.14)), null, glyphShadow);
        dc.DrawGeometry(Brushes.White, null, playing ? Glyphs.Pause(box) : Glyphs.Play(box));
        dc.Pop();
    }
}
