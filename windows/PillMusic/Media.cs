using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Windows.Media.Control;

namespace PillMusic;

enum PlayerState { NotRunning, Stopped, Playing, Paused }

/// Lit et pilote le lecteur en cours via les contrôles multimédias de Windows
/// (Spotify, Apple Music, Deezer, Tidal, navigateurs…) : API officielle, aucune autorisation.
sealed class MediaController
{
    public event Action? Changed;
    /// Position recalée (seek, pause, dérive) : les paroles se resynchronisent.
    public event Action? PositionChanged;
    public event Action? TrackChanged;

    public PlayerState State { get; private set; } = PlayerState.NotRunning;
    public Track? Track { get; private set; }
    public BitmapSource? Artwork { get; private set; }
    public PaletteColors Palette { get; private set; } = PaletteColors.Fallback;
    public string SourceLabel { get; private set; } = "le lecteur";

    GlobalSystemMediaTransportControlsSessionManager? manager;
    GlobalSystemMediaTransportControlsSession? session;
    readonly Dispatcher ui = Application.Current.Dispatcher;

    double positionBase;
    DateTime positionDate = DateTime.UtcNow;
    PlayerState? pendingState;
    DateTime pendingUntil;
    DateTime? stoppedSince;
    string? artworkTrackId;
    readonly Dictionary<string, (BitmapSource?, PaletteColors)> artworkCache = new();
    DispatcherTimer? poll;

    public async void Start()
    {
        try
        {
            manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            manager.CurrentSessionChanged += (_, _) => ui.BeginInvoke(() => { Attach(); Refresh(); });
            manager.SessionsChanged += (_, _) => ui.BeginInvoke(() => { Attach(); Refresh(); });
        }
        catch { }
        Attach();
        Refresh();
        // Les événements suffisent ; l'interrogation ne sert qu'à recaler la position.
        poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        poll.Tick += (_, _) => Refresh();
        poll.Start();
        Power.Changed += () => poll.Interval = TimeSpan.FromSeconds(Power.Saving ? 4 : 2);
    }

    /// Choisit la session : celle qui joue, sinon celle que Windows considère comme active.
    void Attach()
    {
        if (manager == null) return;
        GlobalSystemMediaTransportControlsSession? next = null;
        try
        {
            var sessions = manager.GetSessions();
            next = sessions.FirstOrDefault(s => s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
                   ?? manager.GetCurrentSession()
                   ?? sessions.FirstOrDefault();
        }
        catch { }
        if (ReferenceEquals(next, session)) return;
        if (session != null)
        {
            session.MediaPropertiesChanged -= OnSessionEvent;
            session.PlaybackInfoChanged -= OnSessionEvent;
            session.TimelinePropertiesChanged -= OnSessionEvent;
        }
        session = next;
        if (session != null)
        {
            session.MediaPropertiesChanged += OnSessionEvent;
            session.PlaybackInfoChanged += OnSessionEvent;
            session.TimelinePropertiesChanged += OnSessionEvent;
            SourceLabel = LabelFor(session.SourceAppUserModelId);
        }
    }

    void OnSessionEvent(GlobalSystemMediaTransportControlsSession s, object e) => ui.BeginInvoke(() =>
    {
        // Un autre lecteur se met à jouer : il devient le lecteur suivi.
        if (!ReferenceEquals(s, session)) Attach();
        Refresh();
    });

    static string LabelFor(string aumid)
    {
        var a = aumid.ToLowerInvariant();
        if (a.Contains("spotify")) return "Spotify";
        if (a.Contains("applemusic") || a.Contains("itunes")) return "Apple Music";
        if (a.Contains("deezer")) return "Deezer";
        if (a.Contains("tidal")) return "Tidal";
        if (a.Contains("chrome")) return "Chrome";
        if (a.Contains("msedge")) return "Edge";
        if (a.Contains("firefox")) return "Firefox";
        return "le lecteur";
    }

    /// Position actuelle, interpolée entre deux lectures pour une barre fluide.
    public double Position(DateTime now)
    {
        if (Track == null) return 0;
        double p = State == PlayerState.Playing ? positionBase + (now - positionDate).TotalSeconds : positionBase;
        return Math.Clamp(p, 0, Math.Max(Track.Duration, 0));
    }

    /// Rendu de test uniquement : morceau fictif.
    public void LoadDemo(BitmapSource? art)
    {
        Track = new Track("demo", "Ain't in LA", "ADÉLA", "", 173);
        State = PlayerState.Paused;
        positionBase = 128;
        Artwork = art;
        Palette = art != null ? PillMusic.Palette.Extract(art) ?? PaletteColors.Fallback : PaletteColors.Fallback;
    }

    // MARK: Actions

    public async void PlayPause()
    {
        if (session == null) return;
        // Réponse visuelle immédiate, confirmée ensuite par le lecteur.
        if (State == PlayerState.Playing) { positionBase = Position(DateTime.UtcNow); positionDate = DateTime.UtcNow; State = PlayerState.Paused; }
        else if (State == PlayerState.Paused) { positionDate = DateTime.UtcNow; State = PlayerState.Playing; }
        pendingState = State;
        pendingUntil = DateTime.UtcNow.AddSeconds(2);
        Changed?.Invoke();
        try { await session.TryTogglePlayPauseAsync(); } catch { }
        RefreshSoon();
    }

    public async void Next()
    {
        if (session == null) return;
        try { await session.TrySkipNextAsync(); } catch { }
        RefreshSoon();
    }

    public async void Previous()
    {
        if (session == null) return;
        try { await session.TrySkipPreviousAsync(); } catch { }
        RefreshSoon();
    }

    public async void Seek(double seconds)
    {
        if (session == null || Track == null) return;
        positionBase = seconds; positionDate = DateTime.UtcNow;
        Changed?.Invoke();
        PositionChanged?.Invoke();
        try { await session.TryChangePlaybackPositionAsync(TimeSpan.FromSeconds(seconds).Ticks); } catch { }
        RefreshSoon();
    }

    /// Ouvre le lecteur en cours.
    public void OpenPlayer()
    {
        var id = session?.SourceAppUserModelId;
        try
        {
            if (id == null) return;
            if (id.Contains("Spotify", StringComparison.OrdinalIgnoreCase))
                Process.Start(new ProcessStartInfo("spotify:") { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo("explorer.exe", $"shell:AppsFolder\\{id}") { UseShellExecute = true });
        }
        catch { }
    }

    void RefreshSoon()
    {
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        t.Tick += (_, _) => { t.Stop(); Refresh(); };
        t.Start();
    }

    // MARK: Lecture de l'état

    public async void Refresh()
    {
        if (session == null)
        {
            if (State != PlayerState.NotRunning || Track != null)
            {
                State = PlayerState.NotRunning;
                SetTrack(null);
                SetArtwork(null, PaletteColors.Fallback);
                Changed?.Invoke();
            }
            return;
        }

        GlobalSystemMediaTransportControlsSessionMediaProperties? props = null;
        GlobalSystemMediaTransportControlsSessionPlaybackInfo? info;
        GlobalSystemMediaTransportControlsSessionTimelineProperties? timeline;
        var s = session;
        try
        {
            info = s.GetPlaybackInfo();
            timeline = s.GetTimelineProperties();
            props = await s.TryGetMediaPropertiesAsync();
        }
        catch { return; }
        if (!ReferenceEquals(s, session)) return;

        var newState = info?.PlaybackStatus switch
        {
            GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing => PlayerState.Playing,
            GlobalSystemMediaTransportControlsSessionPlaybackStatus.Paused => PlayerState.Paused,
            GlobalSystemMediaTransportControlsSessionPlaybackStatus.Changing => State,
            GlobalSystemMediaTransportControlsSessionPlaybackStatus.Opened => State == PlayerState.NotRunning ? PlayerState.Paused : State,
            _ => PlayerState.Stopped,
        };
        if (pendingState is { } pending)
        {
            if (newState == pending || DateTime.UtcNow > pendingUntil) pendingState = null;
            else if (newState is PlayerState.Playing or PlayerState.Paused) newState = pending; // réponse encore périmée
        }

        var title = props?.Title ?? "";
        if (newState == PlayerState.Stopped || title.Length == 0)
        {
            // Ne vide la pilule que si l'arrêt dure vraiment (pas le blanc entre deux titres).
            stoppedSince ??= DateTime.UtcNow;
            if (Track != null && (DateTime.UtcNow - stoppedSince.Value).TotalSeconds < 4) return;
            if (State != PlayerState.Stopped || Track != null)
            {
                State = PlayerState.Stopped;
                SetTrack(null);
                SetArtwork(null, PaletteColors.Fallback);
                Changed?.Invoke();
            }
            return;
        }
        stoppedSince = null;

        var artist = props?.Artist ?? "";
        if (artist.Length == 0) artist = props?.AlbumArtist ?? "";
        var album = props?.AlbumTitle ?? "";
        double duration = 0, position = 0;
        if (timeline != null)
        {
            duration = Math.Max(0, (timeline.EndTime - timeline.StartTime).TotalSeconds);
            position = (timeline.Position - timeline.StartTime).TotalSeconds;
            // Certains lecteurs ne mettent la position à jour que de temps en temps : on extrapole.
            if (newState == PlayerState.Playing && timeline.LastUpdatedTime.Year > 2000)
                position += Math.Max(0, (DateTimeOffset.Now - timeline.LastUpdatedTime).TotalSeconds);
        }
        var id = $"{s.SourceAppUserModelId}|{title}|{artist}|{album}";
        var track = new Track(id, title, artist, album, duration);
        bool trackChanged = track.Id != Track?.Id;

        // Ne recale la position que si elle a vraiment dérivé, pour éviter les sauts.
        double predicted = Position(DateTime.UtcNow);
        bool resync = trackChanged || newState != State || Math.Abs(predicted - position) > 0.75;
        if (resync) { positionBase = position; positionDate = DateTime.UtcNow; }
        bool changed = resync || track != Track || newState != State;
        SourceLabel = LabelFor(s.SourceAppUserModelId);
        if (track != Track) SetTrack(track);
        State = newState;
        if (changed) Changed?.Invoke();
        if (resync) PositionChanged?.Invoke();
        if (trackChanged || artworkTrackId != track.Id) LoadArtwork(track, props);
    }

    void SetTrack(Track? t)
    {
        bool idChanged = t?.Id != Track?.Id;
        Track = t;
        if (idChanged) TrackChanged?.Invoke();
    }

    // MARK: Pochette

    async void LoadArtwork(Track track, GlobalSystemMediaTransportControlsSessionMediaProperties? props)
    {
        artworkTrackId = track.Id;
        if (artworkCache.TryGetValue(track.Id, out var cached)) { SetArtwork(cached.Item1, cached.Item2); return; }

        BitmapSource? image = null;
        try
        {
            if (props?.Thumbnail != null)
            {
                using var stream = await props.Thumbnail.OpenReadAsync();
                using var net = stream.AsStream();
                var ms = new MemoryStream();
                await net.CopyToAsync(ms);
                ms.Position = 0;
                image = Decode(ms);
            }
        }
        catch { }
        // Les vignettes des navigateurs sont parfois minuscules : pochette de la recherche Apple si elle correspond.
        if (image == null || image.PixelWidth < 64)
        {
            try
            {
                var url = await TrackLink.ArtworkUrl(track);
                if (url != null) image = Decode(new MemoryStream(await Http.Client.GetByteArrayAsync(url))) ?? image;
            }
            catch { }
        }
        image = image != null ? SquareCrop(image) : null;
        var colors = image != null ? await Task.Run(() => PillMusic.Palette.Extract(image) ?? PaletteColors.Fallback) : PaletteColors.Fallback;
        artworkCache[track.Id] = (image, colors);
        if (artworkCache.Count > 40) artworkCache.Clear();
        if (Track?.Id != track.Id) return;
        SetArtwork(image, colors);
    }

    static BitmapSource? Decode(Stream s)
    {
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelWidth = 600;
            bmp.StreamSource = s;
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch { return null; }
    }

    /// Spotify fournit parfois une vignette 16:9 avec des bandes : on garde le carré central.
    static BitmapSource SquareCrop(BitmapSource b)
    {
        if (Math.Abs(b.PixelWidth - b.PixelHeight) <= 2) return b;
        int side = Math.Min(b.PixelWidth, b.PixelHeight);
        var crop = new CroppedBitmap(b, new Int32Rect((b.PixelWidth - side) / 2, (b.PixelHeight - side) / 2, side, side));
        crop.Freeze();
        return crop;
    }

    void SetArtwork(BitmapSource? image, PaletteColors colors)
    {
        if (image == null) artworkTrackId = null;
        Artwork = image;
        Palette = colors;
        Changed?.Invoke();
    }
}
