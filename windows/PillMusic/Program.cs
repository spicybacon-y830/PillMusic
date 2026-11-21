using System;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace PillMusic;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--render") { RenderTest.Run(args[1], args.Length > 2 ? args[2] : null); return; }

        // Une seule pilule : relancer l'app ré-affiche la pilule existante.
        using var mutex = new Mutex(true, "PillMusic.SingleInstance", out bool first);
        using var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "PillMusic.Show");
        if (!first) { showSignal.Set(); return; }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var controller = new AppController(showSignal);
        app.Startup += (_, _) => controller.Start();
        app.Run();
    }
}

sealed class AppController
{
    readonly Settings settings = Settings.Load();
    MediaController media = null!;
    LiquidMetal metal = null!;
    LyricsModel lyrics = null!;
    PillWindow pill = null!;
    LyricsWindow lyricsWindow = null!;
    Forms.NotifyIcon tray = null!;
    readonly EventWaitHandle showSignal;
    bool userHidden;
    const int HotKeyId = 0x50494C;

    public AppController(EventWaitHandle showSignal) => this.showSignal = showSignal;

    public void Start()
    {
        Power.Start();
        media = new MediaController();
        metal = new LiquidMetal();
        lyrics = new LyricsModel(media, settings);
        pill = new PillWindow(settings, media, metal, lyrics);
        lyricsWindow = new LyricsWindow(lyrics, settings);

        PlaceAtSavedPosition();
        pill.Show();
        pill.View.SetShown(true);
        pill.View.KeepOnScreen(animated: false);

        pill.Moved += () => { PlaceLyrics(); };
        pill.View.OnArtworkClick = media.OpenPlayer;
        pill.View.OnArtworkDoubleClick = CopyTrackLink;
        pill.View.OnRightClick = () => BuildMenu().Show(Forms.Cursor.Position);
        pill.LocationChanged += (_, _) => SaveCenterSoon();

        // ⌃⌥M : afficher / masquer la pilule depuis n'importe quelle app.
        pill.SourceInitialized += (_, _) => RegisterHotKey();
        RegisterHotKey();
        pill.HotKey += id => { if (id == HotKeyId) TogglePill(); };

        media.Changed += UpdateLyricsVisibility;
        lyrics.Changed += UpdateLyricsVisibility;
        media.Start();

        SetupTray();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, _) => pill.Dispatcher.BeginInvoke(() => pill.View.InvalidateVisual());
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => pill.Dispatcher.BeginInvoke(RescueIfOffscreen);

        // Signal d'une seconde instance : on ré-affiche la pilule.
        ThreadPool.RegisterWaitForSingleObject(showSignal, (_, _) => pill.Dispatcher.BeginInvoke(() => { userHidden = false; ShowPill(true); }), null, -1, false);

        // Première ouverture : lancement au démarrage de Windows (désactivable dans le menu).
        if (!settings.DidEnableStartupOnce)
        {
            settings.DidEnableStartupOnce = true;
            try { Settings.LaunchAtStartup = true; } catch { }
            settings.Save();
        }
    }

    void RegisterHotKey()
    {
        var h = new System.Windows.Interop.WindowInteropHelper(pill).Handle;
        if (h == IntPtr.Zero) return;
        Native.UnregisterHotKey(h, HotKeyId);
        Native.RegisterHotKey(h, HotKeyId, Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, 0x4D /* M */);
    }

    // MARK: Position

    void PlaceAtSavedPosition()
    {
        double scale = 1;
        var src = PresentationSource.FromVisual(pill);
        if (src?.CompositionTarget != null) scale = src.CompositionTarget.TransformToDevice.M11;
        Point center;
        if (settings.CenterX is { } x && settings.CenterY is { } y && Native.OnAnyScreen(new Point(x, y), scale)) center = new Point(x, y);
        else
        {
            // Par défaut : en haut au centre de l'écran principal.
            var wa = Native.PrimaryWorkArea(scale);
            center = new Point(wa.Left + wa.Width / 2, wa.Top + Design.MarginY + Design.Height * settings.Scale / 2 + 16);
        }
        pill.Left = center.X - pill.Width / 2;
        pill.Top = center.Y - pill.Height / 2;
    }

    DispatcherTimer? saveTimer;
    void SaveCenterSoon()
    {
        saveTimer ??= new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        saveTimer.Stop();
        saveTimer.Tick -= SaveTick;
        saveTimer.Tick += SaveTick;
        saveTimer.Start();
    }

    void SaveTick(object? s, EventArgs e)
    {
        saveTimer!.Stop();
        settings.CenterX = pill.Left + pill.Width / 2;
        settings.CenterY = pill.Top + pill.Height / 2;
        settings.Save();
    }

    /// Écran débranché ou résolution changée : la pilule revient si elle est hors des écrans.
    void RescueIfOffscreen()
    {
        double scale = Native.DpiScale(pill);
        var c = new Point(pill.Left + pill.Width / 2, pill.Top + pill.Height / 2);
        if (!Native.OnAnyScreen(c, scale))
        {
            settings.CenterX = settings.CenterY = null;
            PlaceAtSavedPosition();
        }
        pill.View.KeepOnScreen();
        PlaceLyrics();
    }

    void ApplySize(PillSize size)
    {
        var c = new Point(pill.Left + pill.Width / 2, pill.Top + pill.Height / 2);
        settings.Size = size;
        settings.Save();
        pill.ApplySize();
        pill.Left = c.X - pill.Width / 2;
        pill.Top = c.Y - pill.Height / 2;
        pill.View.KeepOnScreen();
        lyricsWindow.ApplyScale(settings.Scale);
        PlaceLyrics();
    }

    // MARK: Affichage

    void ShowPill(bool visible)
    {
        pill.View.SetShown(visible);
        UpdateLyricsVisibility();
    }

    void TogglePill()
    {
        userHidden = pill.View.Shown;
        ShowPill(!userHidden);
    }

    // MARK: Paroles

    void UpdateLyricsVisibility()
    {
        bool visible = lyrics.Enabled && pill.View.Shown && media.Track != null;
        if (visible) PlaceLyrics();
        if (visible != lyricsWindow.IsVisible || visible) lyricsWindow.SetShown(visible);
    }

    void PlaceLyrics()
    {
        double m = LyricsWindow.Pad;
        var pillRect = pill.View.CollapsedScreenRect();
        var wa = Native.WorkArea(new Point(pillRect.X + pillRect.Width / 2, pillRect.Y + pillRect.Height / 2), Native.DpiScale(pill));
        const double gap = 4;
        // Collées au bord de la pilule : au-dessus si la place le permet, sinon en dessous.
        double h = lyricsWindow.Height;
        bool below = pillRect.Top - gap - h + m < wa.Top;
        lyricsWindow.Below = below;
        lyricsWindow.Left = pill.Left + pill.Width / 2 - lyricsWindow.Width / 2;
        lyricsWindow.Top = below ? pillRect.Bottom + gap : pillRect.Top - gap - h;
    }

    // MARK: Lien du morceau

    async void CopyTrackLink()
    {
        if (media.Track is not { } track) return;
        pill.View.SetLink(LinkStatus.Loading);
        var url = await TrackLink.Find(track);
        if (url != null) { try { Clipboard.SetText(url); } catch { } }
        pill.View.SetLink(url != null ? LinkStatus.Copied : LinkStatus.Failed);
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.3) };
        t.Tick += (_, _) => { t.Stop(); pill.View.SetLink(null); };
        t.Start();
    }

    // MARK: Menu et zone de notification

    void SetupTray()
    {
        System.Drawing.Icon icon;
        try
        {
            using var s = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/AppIcon.ico")).Stream;
            icon = new System.Drawing.Icon(s, 32, 32);
        }
        catch { icon = System.Drawing.SystemIcons.Application; }
        tray = new Forms.NotifyIcon { Icon = icon, Text = "PillMusic", Visible = true };
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) TogglePill();
            else BuildMenu().Show(Forms.Cursor.Position);
        };
    }

    Forms.ContextMenuStrip BuildMenu()
    {
        var menu = new Forms.ContextMenuStrip { ShowImageMargin = false, ShowCheckMargin = true };
        Forms.ToolStripMenuItem Item(string text, Action action, bool check = false)
        {
            var it = new Forms.ToolStripMenuItem(text) { Checked = check };
            it.Click += (_, _) => action();
            return it;
        }

        menu.Items.Add(Item(pill.View.Shown ? "Masquer la pilule\tCtrl+Alt+M" : "Afficher la pilule\tCtrl+Alt+M", TogglePill));
        menu.Items.Add(Item("Ouvrir le lecteur", media.OpenPlayer));
        menu.Items.Add(Item("Morceau suivant", () => { pill.View.SkipDirection = 1; media.Next(); }));
        menu.Items.Add(Item("Morceau précédent", () => { pill.View.SkipDirection = -1; media.Previous(); }));
        menu.Items.Add(Item("Paroles", () => { lyrics.Enabled = !lyrics.Enabled; pill.View.LyricsToggled(); }, lyrics.Enabled));
        menu.Items.Add(new Forms.ToolStripSeparator());

        var size = new Forms.ToolStripMenuItem("Taille");
        foreach (PillSize s in Enum.GetValues(typeof(PillSize)))
            size.DropDownItems.Add(Item(Settings.Label(s), () => ApplySize(s), settings.Size == s));
        menu.Items.Add(size);

        var look = new Forms.ToolStripMenuItem("Apparence");
        foreach (PillAppearance a in Enum.GetValues(typeof(PillAppearance)))
            look.DropDownItems.Add(Item(Settings.Label(a), () => { settings.Appearance = a; settings.Save(); pill.View.InvalidateVisual(); }, settings.Appearance == a));
        menu.Items.Add(look);

        bool startup = false;
        try { startup = Settings.LaunchAtStartup; } catch { }
        menu.Items.Add(Item("Lancer au démarrage de Windows", () => { try { Settings.LaunchAtStartup = !startup; } catch { } }, startup));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Item("Quitter PillMusic", () =>
        {
            tray.Visible = false;
            tray.Dispose();
            Application.Current.Shutdown();
        }));
        return menu;
    }
}

/// Rendu de vérification (sans lecteur) : pilule fermée, ouverte, sombre, en PNG.
/// Usage : PillMusic.exe --render sortie.png [pochette.png]
static class RenderTest
{
    public static void Run(string output, string? artPath)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += (_, _) =>
        {
            BitmapSource? art = null;
            if (artPath != null && File.Exists(artPath))
            {
                var b = new BitmapImage();
                b.BeginInit(); b.UriSource = new Uri(Path.GetFullPath(artPath)); b.CacheOption = BitmapCacheOption.OnLoad; b.EndInit(); b.Freeze();
                art = b;
            }
            var frames = new System.Collections.Generic.List<BitmapSource>();
            foreach (var (expanded, dark, lyricsOn) in new[] { (false, false, false), (true, false, true), (true, true, false) })
            {
                var settings = new Settings { Appearance = dark ? PillAppearance.Dark : PillAppearance.Light, LyricsEnabled = lyricsOn };
                var media = new MediaController();
                media.LoadDemo(art);
                var metal = new LiquidMetal();
                var lyrics = new LyricsModel(media, settings);
                var win = new PillWindow(settings, media, metal, lyrics);
                var view = win.View;
                ((System.Windows.Controls.Canvas)win.Content).Background = new SolidColorBrush(Color.FromRgb(204, 204, 204));
                view.RenderDemo(expanded);
                metal.Pixels = (int)(Design.Disc * settings.Scale * 3);
                metal.SetPalette(media.Palette);
                metal.RenderNow();
                var root = (FrameworkElement)win.Content;
                root.Measure(new Size(win.Width, win.Height));
                root.Arrange(new Rect(0, 0, win.Width, win.Height));
                root.UpdateLayout();
                view.InvalidateVisual();
                root.UpdateLayout();
                var rtb = new RenderTargetBitmap((int)(win.Width * 3), (int)(win.Height * 3), 96 * 3, 96 * 3, PixelFormats.Pbgra32);
                rtb.Render(root);
                if (!lyricsOn) { frames.Add(rtb); continue; }

                // Paroles au-dessus de la pilule.
                lyrics.LoadDemo(new() { new(0, "I was walking down the street"), new(4, "Thinking 'bout the way you said my name, and every single thing we never got to say"), new(9, "") }, 1);
                var lw = new LyricsWindow(lyrics, settings);
                lw.ShowNow();
                var lroot = (FrameworkElement)lw.Content;
                lroot.Measure(new Size(lw.Width, lw.Height));
                lroot.Arrange(new Rect(0, 0, lw.Width, lw.Height));
                lroot.UpdateLayout();
                var lrtb = new RenderTargetBitmap((int)(lw.Width * 3), (int)(lw.Height * 3), 96 * 3, 96 * 3, PixelFormats.Pbgra32);
                lrtb.Render(lroot);
                var combo = new DrawingVisual();
                using (var dc = combo.RenderOpen())
                {
                    dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(204, 204, 204)), null, new Rect(0, 0, rtb.PixelWidth, rtb.PixelHeight + lrtb.PixelHeight));
                    dc.DrawImage(lrtb, new Rect((rtb.PixelWidth - lrtb.PixelWidth) / 2.0, 0, lrtb.PixelWidth, lrtb.PixelHeight));
                    dc.DrawImage(rtb, new Rect(0, lrtb.PixelHeight - (Design.MarginY - 4) * 3, rtb.PixelWidth, rtb.PixelHeight));
                }
                var both = new RenderTargetBitmap(rtb.PixelWidth, rtb.PixelHeight + lrtb.PixelHeight, 96, 96, PixelFormats.Pbgra32);
                both.Render(combo);
                frames.Add(both);
            }
            int w = 0, h = 0;
            foreach (var f in frames) { w = Math.Max(w, f.PixelWidth); h += f.PixelHeight; }
            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen())
            {
                double y = 0;
                foreach (var f in frames) { dc.DrawImage(f, new Rect(0, y, f.PixelWidth, f.PixelHeight)); y += f.PixelHeight; }
            }
            var sheet = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
            sheet.Render(dv);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(sheet));
            using (var fs = File.Create(output)) enc.Save(fs);
            app.Shutdown();
        };
        app.Run();
    }
}
