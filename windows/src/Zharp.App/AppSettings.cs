using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zharp.App;

/// <summary>One tab snapshot: enough to reopen the same shell in the same place.
/// Shell is the id from ShellDiscovery; empty = the configured default shell.</summary>
public sealed class SavedSession
{
    [JsonPropertyName("shell")]
    public string Shell { get; set; } = "";

    [JsonPropertyName("directory")]
    public string Directory { get; set; } = "";
}

/// <summary>
/// User settings persisted to %LOCALAPPDATA%\Zharp\settings.json.
/// </summary>
public sealed class AppSettings
{
    /// <summary>Theme id: cream (default), paper, rose, dark, navy, tokyo,
    /// dracula, catppuccin, gruvbox.</summary>
    [JsonPropertyName("theme")]
    public string Theme { get; set; } = "cream";

    /// <summary>"mica" (default) or "acrylic" - the window backdrop material.</summary>
    [JsonPropertyName("backdrop")]
    public string Backdrop { get; set; } = "mica";

    /// <summary>Chrome/terminal background opacity, 0.5-1.0. Lower = more backdrop blur.</summary>
    [JsonPropertyName("backgroundOpacity")]
    public double BackgroundOpacity { get; set; } = 0.94;

    [JsonIgnore]
    public bool IsDarkTheme => Themes.Get(Theme).IsDark;

    /// <summary>"sidebar" (vertical tab list) or "top" (horizontal strip).</summary>
    [JsonPropertyName("tabLayout")]
    public string TabLayout { get; set; } = "sidebar";

    /// <summary>"comfortable" (two-line cards) or "compact" (single-line).</summary>
    [JsonPropertyName("sidebarDensity")]
    public string SidebarDensity { get; set; } = "comfortable";

    /// <summary>"shell" (shell/app name as card title) or "cwd" (working directory).</summary>
    [JsonPropertyName("sidebarTitleMode")]
    public string SidebarTitleMode { get; set; } = "shell";

    /// <summary>Show the second line (path or shell name) on sidebar cards.</summary>
    [JsonPropertyName("sidebarShowPath")]
    public bool SidebarShowPath { get; set; } = true;

    /// <summary>Show the tab-search box at the top of the sidebar; off shows a
    /// "Sessions" label instead.</summary>
    [JsonPropertyName("sidebarShowSearch")]
    public bool SidebarShowSearch { get; set; } = true;

    [JsonIgnore]
    public bool SidebarCompact => string.Equals(SidebarDensity, "compact", StringComparison.OrdinalIgnoreCase);

    [JsonIgnore]
    public bool SidebarTitleIsCwd => string.Equals(SidebarTitleMode, "cwd", StringComparison.OrdinalIgnoreCase);

    [JsonPropertyName("sidebarVisible")]
    public bool SidebarVisible { get; set; } = true;

    /// <summary>
    /// When true, NO_COLOR is removed from the environment of shells Zharp
    /// spawns, so tools emit ANSI colors even if it is set system-wide.
    /// </summary>
    [JsonPropertyName("overrideNoColor")]
    public bool OverrideNoColor { get; set; } = true;

    [JsonPropertyName("fontSize")]
    public double FontSize { get; set; } = 13;

    [JsonPropertyName("fontFamily")]
    public string FontFamily { get; set; } = "Cascadia Mono";

    /// <summary>"block", "underline" or "bar" - used when apps don't set one (DECSCUSR).</summary>
    [JsonPropertyName("cursorStyle")]
    public string CursorStyle { get; set; } = "block";

    /// <summary>"top" (classic), "bottom" (prompt hugs the bottom edge) or
    /// "pinTop" (view anchors to the prompt line).</summary>
    [JsonPropertyName("inputPosition")]
    public string InputPosition { get; set; } = "top";

    /// <summary>Maps the input-position name to TerminalView's mode code.</summary>
    public static int InputPositionToCode(string? value) => value?.ToLowerInvariant() switch
    {
        "bottom" => 1,
        "pintop" or "pin-top" => 2,
        _ => 0,
    };

    [JsonPropertyName("scrollbackLines")]
    public int ScrollbackLines { get; set; } = 10000;

    /// <summary>"auto", "pwsh", "powershell" or "cmd".</summary>
    [JsonPropertyName("shell")]
    public string Shell { get; set; } = "auto";

    /// <summary>Where new terminals start. Empty = the user profile folder.</summary>
    [JsonPropertyName("defaultDirectory")]
    public string DefaultDirectory { get; set; } = "";

    /// <summary>Working directory of the most recently closed terminal tab.</summary>
    [JsonPropertyName("lastClosedDirectory")]
    public string LastClosedDirectory { get; set; } = "";

    /// <summary>Reopen the tabs from the previous run on launch.</summary>
    [JsonPropertyName("restoreSessions")]
    public bool RestoreSessions { get; set; } = true;

    /// <summary>Terminal tabs open when the app last quit, in sidebar order.</summary>
    [JsonPropertyName("savedSessions")]
    public List<SavedSession> SavedSessions { get; set; } = new();

    /// <summary>Index of the active tab within <see cref="SavedSessions"/>.</summary>
    [JsonPropertyName("savedActiveIndex")]
    public int SavedActiveIndex { get; set; }

    /// <summary>True once the first-run onboarding has been completed or skipped.</summary>
    [JsonPropertyName("onboarded")]
    public bool Onboarded { get; set; }

    /// <summary>Website base URL serving /api/version and /download (update channel).</summary>
    [JsonPropertyName("updateBaseUrl")]
    public string UpdateBaseUrl { get; set; } = "https://zharp.app";

    /// <summary>Version the user was last toasted about, so each release notifies once.</summary>
    [JsonPropertyName("lastNotifiedUpdate")]
    public string LastNotifiedUpdate { get; set; } = "";

    /// <summary>Whole-UI zoom factor (Ctrl + +/-/0), 0.7-1.5.</summary>
    [JsonPropertyName("uiZoom")]
    public double UiZoom { get; set; } = 1.0;

    [JsonPropertyName("sidebarWidth")]
    public double SidebarWidth { get; set; } = 230;

    /// <summary>Rebindable shortcuts: action id → "Ctrl+Shift+T"-style binding.</summary>
    [JsonPropertyName("keybindings")]
    public Dictionary<string, string> Keybindings { get; set; } = new();

    [JsonIgnore]
    public bool UseSidebar => !string.Equals(TabLayout, "top", StringComparison.OrdinalIgnoreCase);

    /// <summary>Maps the cursor style name to its DECSCUSR-style code.</summary>
    public static int CursorStyleToCode(string? style) => style?.ToLowerInvariant() switch
    {
        "underline" => 3,
        "bar" => 5,
        _ => 0,
    };

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Zharp", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), Options) ?? new AppSettings();
        }
        catch
        {
            // Corrupt settings fall back to defaults.
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, Options));
        }
        catch
        {
            // Non-fatal: settings just won't persist.
        }
    }
}
