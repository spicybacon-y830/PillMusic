using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace PillMusic;

record LyricLine(double Time, string Text);

enum LyricsStatus { Idle, Loading, None, Unsynced, Ready }

/// Paroles synchronisées via LRCLIB (base ouverte, sans compte) : on n'envoie que le titre,
/// l'artiste, l'album et la durée. Suit la ligne en cours sans rafraîchissement continu.
sealed class LyricsModel
{
    public event Action? Changed;
    readonly MediaController media;
    readonly Settings settings;
    public LyricsStatus Status { get; private set; } = LyricsStatus.Idle;
    public List<LyricLine> Lines { get; private set; } = new();
    /// Ligne en cours (-1 : avant la première ligne).
    public int Index { get; private set; } = -1;
    public bool Browsing { get; private set; }

    /// Les paroles apparaissent un poil en avance : la lecture paraît plus naturelle.
    const double Lead = 0.25;
    readonly DispatcherTimer timer;
    readonly DispatcherTimer browseEnd;
    string? loadedTrackId;
    readonly Dictionary<string, List<LyricLine>?> cache = new();

    public LyricsModel(MediaController media, Settings settings)
    {
        this.media = media; this.settings = settings;
        timer = new DispatcherTimer(DispatcherPriority.Render);
        timer.Tick += (_, _) => { timer.Stop(); Sync(); };
        browseEnd = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        browseEnd.Tick += (_, _) => { browseEnd.Stop(); Browsing = false; Changed?.Invoke(); };
        media.TrackChanged += () => Load(media.Track);
        media.Changed += Sync;
        media.PositionChanged += Sync;
    }

    public bool Enabled
    {
        get => settings.LyricsEnabled;
        set
        {
            settings.LyricsEnabled = value; settings.Save();
            if (value) Load(media.Track); else timer.Stop();
            Changed?.Invoke();
        }
    }

    /// Rendu de test uniquement.
    public void LoadDemo(List<LyricLine> lines, int index)
    {
        Lines = lines; Status = LyricsStatus.Ready; Index = index;
        Changed?.Invoke();
    }

    /// Molette sur les paroles : on consulte, puis retour automatique à la ligne en cours.
    public void UserScrolled()
    {
        if (!Browsing) { Browsing = true; Changed?.Invoke(); }
        browseEnd.Stop(); browseEnd.Start();
    }

    async void Load(Track? track)
    {
        if (!Enabled || track == null)
        {
            if (track == null) { loadedTrackId = null; Lines = new(); Status = LyricsStatus.Idle; Index = -1; timer.Stop(); Changed?.Invoke(); }
            return;
        }
        if (track.Id == loadedTrackId) { Sync(); return; }
        loadedTrackId = track.Id;
        Index = -1;
        Browsing = false;
        if (cache.TryGetValue(track.Id, out var cached)) { Apply(cached); return; }
        Lines = new();
        Status = LyricsStatus.Loading;
        timer.Stop();
        Changed?.Invoke();
        var result = await Fetch(track);
        cache[track.Id] = result;
        if (cache.Count > 60) cache.Clear();
        if (loadedTrackId != track.Id) return;
        Apply(result);
    }

    void Apply(List<LyricLine>? result)
    {
        if (result is { Count: > 0 }) { Lines = result; Status = LyricsStatus.Ready; }
        else if (result != null) { Lines = new(); Status = LyricsStatus.Unsynced; }
        else { Lines = new(); Status = LyricsStatus.None; }
        Changed?.Invoke();
        Sync();
    }

    /// Cale la ligne affichée sur la lecture, puis programme le prochain changement au bon moment.
    public void Sync()
    {
        timer.Stop();
        if (!Enabled || Status != LyricsStatus.Ready) return;
        double position = media.Position(DateTime.UtcNow) + Lead;
        int i = Lines.FindLastIndex(l => l.Time <= position);
        if (i != Index) { Index = i; Changed?.Invoke(); }
        if (media.State != PlayerState.Playing || i + 1 >= Lines.Count) return;
        timer.Interval = TimeSpan.FromSeconds(Math.Max(0.03, Lines[i + 1].Time - position));
        timer.Start();
    }

    // MARK: Réseau

    /// null : rien trouvé ; liste vide : paroles non synchronisées seulement ; sinon les lignes datées.
    static async Task<List<LyricLine>?> Fetch(Track track)
    {
        try
        {
            var url = "https://lrclib.net/api/get?artist_name=" + Uri.EscapeDataString(track.Artist)
                      + "&track_name=" + Uri.EscapeDataString(track.Title)
                      + "&album_name=" + Uri.EscapeDataString(track.Album)
                      + "&duration=" + (int)Math.Round(track.Duration);
            var resp = await Http.Client.GetAsync(url);
            if (resp.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
                var parsed = Parse(doc.RootElement);
                if (parsed != null) return parsed;
            }
            // Repli : recherche plus souple (titre sans « feat. », durée proche).
            var search = "https://lrclib.net/api/search?track_name=" + Uri.EscapeDataString(CleanTitle(track.Title))
                         + "&artist_name=" + Uri.EscapeDataString(track.Artist);
            using var sdoc = JsonDocument.Parse(await Http.Client.GetStringAsync(search));
            var close = sdoc.RootElement.EnumerateArray().Where(r =>
                track.Duration <= 0 || !r.TryGetProperty("duration", out var d) || d.ValueKind != JsonValueKind.Number
                || Math.Abs(d.GetDouble() - track.Duration) <= 4).ToList();
            var synced = close.FirstOrDefault(r => r.TryGetProperty("syncedLyrics", out var s) && s.ValueKind == JsonValueKind.String && s.GetString()!.Length > 0);
            var pick = synced.ValueKind != JsonValueKind.Undefined ? synced : close.FirstOrDefault();
            return pick.ValueKind == JsonValueKind.Undefined ? null : Parse(pick);
        }
        catch { return null; }
    }

    static List<LyricLine>? Parse(JsonElement obj)
    {
        if (obj.TryGetProperty("instrumental", out var ins) && ins.ValueKind == JsonValueKind.True) return null;
        if (obj.TryGetProperty("syncedLyrics", out var s) && s.ValueKind == JsonValueKind.String && s.GetString()!.Length > 0) return ParseLRC(s.GetString()!);
        if (obj.TryGetProperty("plainLyrics", out var p) && p.ValueKind == JsonValueKind.String && p.GetString()!.Length > 0) return new();
        return null;
    }

    static readonly Regex Stamp = new(@"\[(\d+):(\d+(?:[.:]\d+)?)\]", RegexOptions.Compiled);

    public static List<LyricLine> ParseLRC(string lrc)
    {
        var outp = new List<LyricLine>();
        foreach (var raw in lrc.Split('\n'))
        {
            var matches = Stamp.Matches(raw);
            if (matches.Count == 0) continue;
            var last = matches[^1];
            var text = raw[(last.Index + last.Length)..].Trim();
            foreach (Match m in matches)
            {
                double min = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                double sec = double.Parse(m.Groups[2].Value.Replace(':', '.'), CultureInfo.InvariantCulture);
                outp.Add(new LyricLine(min * 60 + sec, text));
            }
        }
        return outp.OrderBy(l => l.Time).ToList();
    }

    static string CleanTitle(string s)
    {
        foreach (var sep in new[] { " (", " [", " - " })
        {
            int i = s.IndexOf(sep, StringComparison.Ordinal);
            if (i >= 0) s = s[..i];
        }
        return s;
    }
}

/// Paroles flottantes, sans fond : au-dessus de la pilule (ou en dessous si elle est en haut de l'écran),
/// alignées à droite, en blanc avec un voile sombre diffus pour rester lisibles sur fond clair.
sealed class LyricsWindow : Window
{
    public const double Pad = 16;
    readonly LyricsView view;
    readonly Grid outer, inner;

    public LyricsWindow(LyricsModel model, Settings settings)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Focusable = false;
        Title = "PillMusic — paroles";
        view = new LyricsView(model, settings);
        // Deux ombres superposées : un voile proche et un halo large, très doux.
        inner = new Grid { Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.24, ShadowDepth = 0, RenderingBias = RenderingBias.Quality } };
        outer = new Grid { Effect = new DropShadowEffect { Color = Colors.Black, Opacity = 0.3, ShadowDepth = 0, RenderingBias = RenderingBias.Quality } };
        inner.Children.Add(view);
        outer.Children.Add(inner);
        Content = outer;
        SourceInitialized += (_, _) => Native.MakeToolWindow(this);
        MouseWheel += (_, e) => { view.Scroll(e.Delta); e.Handled = true; };
        ApplyScale(settings.Scale);
    }

    public void ApplyScale(double scale)
    {
        double k = scale / 0.25;
        ((DropShadowEffect)inner.Effect).BlurRadius = 4.5 * k * 2;
        ((DropShadowEffect)outer.Effect).BlurRadius = 14 * k * 2;
        Width = (Design.Width - 2 * Design.PaddingH) * scale + Pad * 2;
        Height = 50 * k + Pad;
        view.InvalidateVisual();
    }

    public bool Below { get => view.Below; set { view.Below = value; } }

    /// Rendu de test : affichées tout de suite.
    public void ShowNow() => view.ShowNow();

    public void SetShown(bool shown)
    {
        if (shown && !IsVisible) Show();
        view.SetShown(shown, () => { if (!view.IsShown) Hide(); });
    }
}

sealed class LyricsView : FrameworkElement
{
    readonly LyricsModel model;
    readonly Settings settings;
    public bool Below;
    public bool IsShown { get; private set; }

    readonly Spring offset = new(0, 0.7, 0.88);       // position de la colonne
    readonly Spring appear = new(0, 0.5, 0.85);       // léger glissement à l'apparition
    readonly Tween fade = new(0);                     // fondu linéaire
    readonly Dictionary<int, Tween> lineOpacity = new();
    double browseOffset;
    Action? onHidden;
    bool rendering;
    DateTime last;
    int lastIndex = int.MinValue;
    List<LyricLine>? lastLines;
    bool lastBrowsing;

    public LyricsView(LyricsModel model, Settings settings)
    {
        this.model = model; this.settings = settings;
        IsHitTestVisible = true;
        model.Changed += OnModelChanged;
    }

    double K => settings.Scale / 0.25;

    public void SetShown(bool shown, Action hidden)
    {
        IsShown = shown;
        onHidden = hidden;
        fade.Set(shown ? 1 : 0, 0.3);
        appear.Target = shown ? 1 : 0;
        Kick();
    }

    public void ShowNow() { IsShown = true; fade.Snap(1); appear.Snap(1); }

    public void Scroll(int delta)
    {
        if (model.Status != LyricsStatus.Ready) return;
        model.UserScrolled();
        browseOffset += delta / 120.0 * 22 * K;
        Kick();
    }

    void OnModelChanged()
    {
        if (model.Index != lastIndex || model.Browsing != lastBrowsing)
        {
            bool linesChanged = model.Index != lastIndex;
            lastIndex = model.Index;
            if (!model.Browsing && lastBrowsing)
            {
                // Fin de la consultation : retour en douceur à la ligne en cours.
                offset.Configure(0.8, 1);
                offset.Value += browseOffset;
                browseOffset = 0;
            }
            else if (linesChanged) offset.Configure(0.7, 0.88);
            lastBrowsing = model.Browsing;
        }
        Kick();
    }

    void Kick()
    {
        if (rendering) { InvalidateVisual(); return; }
        rendering = true;
        last = DateTime.UtcNow;
        CompositionTarget.Rendering += OnFrame;
    }

    void OnFrame(object? s, EventArgs e)
    {
        var now = DateTime.UtcNow;
        double dt = Math.Min((now - last).TotalSeconds, 0.05);
        last = now;
        bool active = offset.Step(dt) | appear.Step(dt) | fade.Step(dt);
        foreach (var t in lineOpacity.Values) active |= t.Step(dt);
        InvalidateVisual();
        if (!active)
        {
            CompositionTarget.Rendering -= OnFrame;
            rendering = false;
            if (!IsShown) onHidden?.Invoke();
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        double k = K, m = LyricsWindow.Pad;
        double dpi = Native.DpiScale(this);
        // Zone utile : marges latérales pour l'ombre, et côté opposé à la pilule.
        var area = new Rect(m, Below ? 0 : m, Math.Max(0, ActualWidth - 2 * m), Math.Max(0, ActualHeight - m));
        double fontSize = 13.5 * k;
        double lineGap = 4 * k;
        double edge = 8 * k; // bande de fondu côté pilule

        // Apparition indépendante de la pilule : léger glissement + fondu linéaire.
        double slide = (1 - appear.Value) * (Below ? -8 : 8) * k;
        dc.PushTransform(new TranslateTransform(0, slide));
        dc.PushOpacity(fade.Value);

        string? message = model.Status switch
        {
            LyricsStatus.Loading => "Recherche des paroles…",
            LyricsStatus.None => "Pas de paroles pour ce morceau",
            LyricsStatus.Unsynced => "Paroles non synchronisées",
            _ => null,
        };
        if (message != null)
        {
            var ft = Line(message, area.Width, fontSize, dpi);
            double y = Below ? area.Top + edge : area.Bottom - edge - ft.Height;
            dc.PushOpacity(0.6);
            dc.DrawText(ft, new Point(area.Left, y));
            dc.Pop();
        }
        else if (model.Status == LyricsStatus.Ready)
        {
            DrawColumn(dc, area, fontSize, lineGap, edge, dpi);
        }
        dc.Pop(); dc.Pop();
    }

    FormattedText Line(string text, double width, double size, double dpi)
    {
        var ft = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Design.Font, size, Brushes.White, dpi)
        {
            MaxTextWidth = Math.Max(1, width),
            MaxLineCount = 2,
            TextAlignment = TextAlignment.Right,
            Trimming = TextTrimming.CharacterEllipsis,
        };
        // Phrase trop longue pour deux lignes : on réduit un peu le texte avant de couper.
        var full = new FormattedText(text, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Design.Font, size, Brushes.White, dpi)
        {
            MaxTextWidth = Math.Max(1, width),
        };
        var one = new FormattedText("Ag", CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Design.Font, size, Brushes.White, dpi);
        if (full.Height > one.Height * 2 + 1) ft.SetFontSize(size * 0.8);
        return ft;
    }

    void DrawColumn(DrawingContext dc, Rect area, double fontSize, double gap, double edge, double dpi)
    {
        // [-1 : ♪ avant la première ligne] + lignes ; une ligne vide est un passage instrumental (♪).
        var items = new List<(int i, string text)> { (-1, "") };
        for (int i = 0; i < model.Lines.Count; i++) items.Add((i, model.Lines[i].Text));
        int current = model.Index;
        int faint = Below ? 1 : -1;

        // Hauteurs et positions de toutes les lignes dans la colonne.
        var layouts = new List<(int i, FormattedText? ft, double h)>();
        double noteH = 17 * k();
        foreach (var (i, text) in items)
        {
            if (string.IsNullOrWhiteSpace(text)) layouts.Add((i, null, noteH));
            else { var ft = Line(text, area.Width, fontSize, dpi); layouts.Add((i, ft, ft.Height)); }
        }
        var tops = new double[layouts.Count];
        double y = 0;
        for (int j = 0; j < layouts.Count; j++) { tops[j] = y; y += layouts[j].h + gap; }

        // La ligne en cours est ancrée côté pilule (en bas au-dessus de la pilule, en haut en dessous).
        int cj = Math.Max(0, layouts.FindIndex(t => t.i == current));
        double anchor = Below ? area.Top + edge - tops[cj] : area.Bottom - edge - (tops[cj] + layouts[cj].h);
        if (!ReferenceEquals(model.Lines, lastLines))
        {
            // Nouveau morceau : la colonne se place directement, sans défiler depuis l'ancien.
            lastLines = model.Lines;
            lineOpacity.Clear();
            offset.Snap(anchor);
        }
        offset.Target = anchor;
        if (offset.Moving) Kick();
        double baseY = offset.Value + browseOffset;

        // Fondu côté pilule : la ligne suivante y apparaît, sans jamais toucher la ligne en cours.
        var mask = new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute, StartPoint = new Point(0, area.Top), EndPoint = new Point(0, area.Bottom) };
        double span = Math.Max(area.Height, 1);
        if (Below)
        {
            mask.GradientStops.Add(new GradientStop(Colors.Transparent, 0));
            mask.GradientStops.Add(new GradientStop(Colors.Black, edge / span));
            mask.GradientStops.Add(new GradientStop(Colors.Black, 1));
        }
        else
        {
            mask.GradientStops.Add(new GradientStop(Colors.Black, 0));
            mask.GradientStops.Add(new GradientStop(Colors.Black, 1 - edge / span));
            mask.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
        }
        var clip = Below ? new Rect(0, area.Top, ActualWidth, ActualHeight) : new Rect(0, 0, ActualWidth, area.Bottom);
        dc.PushClip(new RectangleGeometry(clip));
        dc.PushOpacityMask(mask);
        for (int j = 0; j < layouts.Count; j++)
        {
            var (i, ft, h) = layouts[j];
            int d = i - current;
            double target = d == 0 ? 1 : (model.Browsing ? 0.45 : (d == faint ? 0.32 : 0));
            if (!lineOpacity.TryGetValue(i, out var tw)) { tw = new Tween(target); lineOpacity[i] = tw; }
            if (Math.Abs(tw.Target - target) > 1e-6) { tw.Set(target, model.Browsing != lastBrowsing ? 0.25 : 0.45); Kick(); }
            double op = tw.Value;
            if (op <= 0.002) continue;
            double top = baseY + tops[j];
            if (top > ActualHeight || top + h < 0) continue;
            dc.PushOpacity(op);
            if (ft != null) dc.DrawText(ft, new Point(area.Left, top));
            else
            {
                var note = Design.Text("", 12 * k(), Colors.White, dpi, symbol: true);
                dc.DrawText(note, new Point(area.Right - note.Width, top + (h - note.Height) / 2));
            }
            dc.Pop();
        }
        dc.Pop(); dc.Pop();
        if (lineOpacity.Count > 400) lineOpacity.Clear();
    }

    double k() => K;
}
