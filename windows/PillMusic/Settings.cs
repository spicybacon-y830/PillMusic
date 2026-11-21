using System;
using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace PillMusic;

enum PillSize { Small, Medium, Large }
enum PillAppearance { System, Light, Dark }

/// Réglages enregistrés dans %AppData%\PillMusic\settings.json.
sealed class Settings
{
    public PillSize Size { get; set; } = PillSize.Medium;
    public PillAppearance Appearance { get; set; } = PillAppearance.System;
    public bool LyricsEnabled { get; set; }
    public double? CenterX { get; set; }
    public double? CenterY { get; set; }
    public bool DidEnableStartupOnce { get; set; }

    public double Scale => Size switch { PillSize.Small => 0.20, PillSize.Large => 0.31, _ => 0.25 };

    public static string Label(PillSize s) => s switch { PillSize.Small => "Petite", PillSize.Large => "Grande", _ => "Moyenne" };
    public static string Label(PillAppearance a) => a switch { PillAppearance.Light => "Clair", PillAppearance.Dark => "Sombre", _ => "Comme le système" };

    static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PillMusic");
    static string FilePath => Path.Combine(Dir, "settings.json");

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings(); }
        catch { return new Settings(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    /// Thème sombre effectif (réglage de l'app, sinon celui de Windows).
    public bool IsDark => Appearance switch
    {
        PillAppearance.Dark => true,
        PillAppearance.Light => false,
        _ => SystemIsDark(),
    };

    static bool SystemIsDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    // Lancement au démarrage de Windows (clé Run de l'utilisateur, sans droits administrateur).
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool LaunchAtStartup
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("PillMusic") != null;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("PillMusic", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("PillMusic", false);
        }
    }
}
