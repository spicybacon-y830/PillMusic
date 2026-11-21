using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace PillMusic;

record Track(string Id, string Title, string Artist, string Album, double Duration);

static class Http
{
    public static readonly HttpClient Client = Make();

    static HttpClient Make()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("PillMusic");
        return c;
    }
}

/// Recherche publique d'Apple (iTunes Search API, sans clé) : lien Apple Music du morceau
/// et pochette de secours. On ne garde qu'un résultat qui correspond vraiment — jamais au hasard.
static class TrackLink
{
    static readonly Dictionary<string, string?> cache = new();

    public static async Task<string?> Find(Track track)
    {
        if (cache.TryGetValue(track.Id, out var c)) return c;
        var local = (RegionInfo.CurrentRegion.TwoLetterISORegionName ?? "US").ToUpperInvariant();
        var result = await Lookup(track, songOnly: true);
        string? url = null;
        if (result != null && result.Value.TryGetProperty("trackViewUrl", out var v) && Uri.TryCreate(v.GetString(), UriKind.Absolute, out var link))
        {
            // Lien propre, sans paramètres de suivi, converti vers le pays de l'utilisateur.
            var query = System.Web.HttpUtility.ParseQueryString(link.Query);
            var i = query["i"];
            var path = link.AbsolutePath;
            if (local != "US") path = path.Replace("/us/", $"/{local.ToLowerInvariant()}/");
            url = $"https://music.apple.com{path}" + (i != null ? $"?i={i}" : "");
        }
        cache[track.Id] = url;
        return url;
    }

    public static async Task<string?> ArtworkUrl(Track track)
    {
        var r = await Lookup(track, songOnly: false);
        if (r == null || !r.Value.TryGetProperty("artworkUrl100", out var a)) return null;
        return a.GetString()?.Replace("100x100", "600x600");
    }

    public static async Task<JsonElement?> Lookup(Track track, bool songOnly)
    {
        var local = (RegionInfo.CurrentRegion.TwoLetterISORegionName ?? "US").ToUpperInvariant();
        // Le catalogue local omet parfois des versions (souvent explicites) : repli sur les États-Unis.
        var stores = local == "US" ? new[] { "US" } : new[] { local, "US" };
        foreach (var store in stores)
        {
            try
            {
                var url = "https://itunes.apple.com/search?entity=song&limit=50&country=" + store
                          + "&term=" + Uri.EscapeDataString($"{track.Artist} {track.Title}");
                using var doc = JsonDocument.Parse(await Http.Client.GetStringAsync(url));
                var results = doc.RootElement.GetProperty("results").EnumerateArray().Select(e => e.Clone()).ToList();
                var best = BestMatch(results, track) ?? (songOnly ? null : AlbumMatch(results, track));
                if (best != null) return best;
            }
            catch { }
        }
        return null;
    }

    static string S(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    static bool ArtistMatches(string a, string artist)
    {
        // Strict : l'artiste exact, éventuellement suivi d'invités — jamais une reprise ou un karaoké.
        if (a == artist) return true;
        return new[] { " &", ",", " feat", " x " }.Any(sep => a.StartsWith(artist + sep) || artist.StartsWith(a + sep));
    }

    static JsonElement? AlbumMatch(List<JsonElement> results, Track track)
    {
        var artist = Normalize(track.Artist);
        var album = Fold(track.Album);
        if (album.Length == 0) return null;
        foreach (var r in results)
            if (Fold(S(r, "collectionName")) == album && ArtistMatches(Normalize(S(r, "artistName")), artist)) return r;
        return null;
    }

    static readonly string[] variantWords = { "drumless", "instrumental", "karaoke", "live", "remix", "acoustic", "sped up",
        "slowed", "acapella", "a cappella", "edit", "version", "cover", "remaster" };

    static JsonElement? BestMatch(List<JsonElement> results, Track track)
    {
        string title = Normalize(track.Title), artist = Normalize(track.Artist), album = Normalize(track.Album);
        int Score(JsonElement r)
        {
            string t = Normalize(S(r, "trackName")), a = Normalize(S(r, "artistName")), c = Normalize(S(r, "collectionName"));
            if (t != title || !ArtistMatches(a, artist)) return -1;
            string fullName = Fold(S(r, "trackName")), fullCollection = Fold(S(r, "collectionName"));
            int s = 1;
            if (fullName == Fold(track.Title)) s += 3;
            if (track.Album.Length > 0 && fullCollection == Fold(track.Album)) s += 4;
            else if (album.Length > 0 && c == album) s += 2;
            // Versions alternatives (live, karaoké…) seulement si c'est ce qu'on écoute.
            var source = Fold(track.Title + " " + track.Album);
            foreach (var w in variantWords)
                if ((fullName + " " + fullCollection).Contains(w) && !source.Contains(w)) s -= 3;
            if (S(r, "trackExplicitness") == "explicit") s += 1;
            return s;
        }
        JsonElement? best = null; int bestScore = -1;
        foreach (var r in results)
        {
            int sc = Score(r);
            if (sc > bestScore) { bestScore = sc; best = r; }
        }
        return bestScore >= 0 ? best : null;
    }

    public static string Fold(string s)
    {
        var d = s.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder();
        foreach (var ch in d)
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) sb.Append(ch);
        return sb.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant().Trim();
    }

    /// Minuscules, sans accents, sans mentions entre parenthèses (« feat. », « Remastered »…).
    public static string Normalize(string s)
    {
        var t = Fold(s);
        foreach (var sep in new[] { " (", " [", " - " })
        {
            int i = t.IndexOf(sep, StringComparison.Ordinal);
            if (i >= 0) t = t[..i];
        }
        return t.Trim();
    }
}
