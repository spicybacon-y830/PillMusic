using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace PillMusic;

static class Native
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WM_MOUSEHWHEEL = 0x020E;
    public const int WM_HOTKEY = 0x0312;
    public const int WM_MOUSEACTIVATE = 0x0021;
    public const int MA_NOACTIVATE = 3;
    public const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    /// Fenêtre d'outil (absente de la barre des tâches et d'Alt+Tab) qui ne prend jamais le focus.
    public static void MakeToolWindow(Window w, bool clickThrough = false)
    {
        var h = new WindowInteropHelper(w).EnsureHandle();
        long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
        ex |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
        if (clickThrough) ex |= WS_EX_TRANSPARENT; else ex &= ~WS_EX_TRANSPARENT;
        SetWindowLongPtr(h, GWL_EXSTYLE, new IntPtr(ex));
    }

    /// Position du curseur en pixels physiques.
    public static Point CursorPixels()
    {
        GetCursorPos(out var p);
        return new Point(p.X, p.Y);
    }

    public static double DpiScale(Visual v)
    {
        try { return VisualTreeHelper.GetDpi(v).DpiScaleX; } catch { return 1; }
    }

    /// Zone utile (sans barre des tâches) de l'écran qui contient ce point, en unités WPF.
    public static Rect WorkArea(Point dip, double scale)
    {
        var px = new System.Drawing.Point((int)(dip.X * scale), (int)(dip.Y * scale));
        var wa = System.Windows.Forms.Screen.FromPoint(px).WorkingArea;
        return new Rect(wa.X / scale, wa.Y / scale, wa.Width / scale, wa.Height / scale);
    }

    public static bool OnAnyScreen(Point dip, double scale)
    {
        var px = new System.Drawing.Point((int)(dip.X * scale), (int)(dip.Y * scale));
        foreach (var s in System.Windows.Forms.Screen.AllScreens)
            if (s.Bounds.Contains(px)) return true;
        return false;
    }

    public static Rect PrimaryWorkArea(double scale)
    {
        var wa = System.Windows.Forms.Screen.PrimaryScreen!.WorkingArea;
        return new Rect(wa.X / scale, wa.Y / scale, wa.Width / scale, wa.Height / scale);
    }
}

/// Suit l'alimentation : secteur 60 i/s, batterie 30 i/s, économiseur d'énergie 20 i/s.
static class Power
{
    public static event Action? Changed;
    public static bool OnBattery { get; private set; }
    public static bool LowPower { get; private set; }
    public static bool Saving => OnBattery || LowPower;
    public static double ShaderFPS => LowPower ? 20 : (OnBattery ? 30 : 60);

    public static void Start()
    {
        Update();
        Microsoft.Win32.SystemEvents.PowerModeChanged += (_, _) => Application.Current?.Dispatcher.BeginInvoke(Update);
        try
        {
            Windows.System.Power.PowerManager.EnergySaverStatusChanged += (_, _) => Application.Current?.Dispatcher.BeginInvoke(Update);
        }
        catch { }
    }

    static void Update()
    {
        bool battery = System.Windows.Forms.SystemInformation.PowerStatus.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Offline;
        bool low = false;
        try { low = Windows.System.Power.PowerManager.EnergySaverStatus == Windows.System.Power.EnergySaverStatus.On; } catch { }
        if (battery == OnBattery && low == LowPower) return;
        OnBattery = battery; LowPower = low;
        Changed?.Invoke();
    }
}
