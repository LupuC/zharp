using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Zharp.Core.Terminal;

namespace Zharp.App;

/// <summary>One selectable color theme: chrome colors + terminal palette.</summary>
public sealed record ThemeSpec(
    string Id,
    string Name,
    bool IsDark,
    uint ChromeBackground,
    uint IconColor,
    Func<Palette> CreatePalette);

/// <summary>
/// Theme registry. Chrome brushes live in App.xaml's two ThemeDictionaries
/// (Dark/Light buckets provide the alpha overlays); applying a theme picks the
/// bucket via RequestedTheme and MUTATES the shared brushes' colors in place -
/// every {ThemeResource} reference updates live.
/// </summary>
public static class Themes
{
    public static readonly ThemeSpec[] All =
    [
        new("cream", "Cream", false, 0xEDE6D8, 0x2A2C33, Palette.Cream),
        new("paper", "Paper", false, 0xF6F5F1, 0x24292F, Palette.Paper),
        new("rose", "Rosé", false, 0xFAF4ED, 0x575279, Palette.Rose),
        new("dark", "Dark", true, 0x282828, 0xFFFFFF, Palette.Campbell),
        new("navy", "Navy", true, 0x151E32, 0xD5DEF2, Palette.Navy),
        new("tokyo", "Tokyo", true, 0x1A1B26, 0xC0CAF5, Palette.Tokyo),
        new("dracula", "Dracula", true, 0x282A36, 0xF8F8F2, Palette.Dracula),
        new("catppuccin", "Catppuccin", true, 0x1E1E2E, 0xCDD6F4, Palette.Catppuccin),
        new("gruvbox", "Gruvbox", true, 0x1D2021, 0xEBDBB2, Palette.Gruvbox),
    ];

    public static ThemeSpec Get(string? id) =>
        All.FirstOrDefault(t => string.Equals(t.Id, id, StringComparison.OrdinalIgnoreCase)) ?? All[0];

    /// <summary>
    /// Writes the theme's colors into the active bucket's shared brushes.
    /// <paramref name="backgroundOpacity"/> (0.5-1.0) sets the chrome wash alpha -
    /// lower values let the Mica/Acrylic backdrop show through.
    /// </summary>
    public static void ApplyToResources(ThemeSpec theme, double backgroundOpacity)
    {
        var dictionaries = Application.Current.Resources.ThemeDictionaries;
        if (!dictionaries.TryGetValue(theme.IsDark ? "Dark" : "Light", out object? bucketObj) ||
            bucketObj is not ResourceDictionary bucket)
        {
            return;
        }

        byte washAlpha = (byte)Math.Clamp(backgroundOpacity * 255, 100, 255);
        SetBrush(bucket, "ChromeWashBrush", theme.ChromeBackground, washAlpha);
        SetBrush(bucket, "BarIconBrush", theme.IconColor, 0x9E);
        SetBrush(bucket, "SubtleIconBrush", theme.IconColor, 0x70);
        // Floating panels are opaque and slightly lifted from the chrome color,
        // so they stay readable over terminal text.
        SetBrush(bucket, "FloatingPanelBrush",
            Lift(theme.ChromeBackground, theme.IsDark ? 0.06 : 0.45), 0xFF);
    }

    /// <summary>Blends an RGB color toward white by the given fraction.</summary>
    private static uint Lift(uint rgb, double toWhite)
    {
        uint Channel(int shift)
        {
            uint c = (rgb >> shift) & 0xFF;
            return (uint)Math.Clamp(c + (255 - c) * toWhite, 0, 255);
        }
        return (Channel(16) << 16) | (Channel(8) << 8) | Channel(0);
    }

    private static void SetBrush(ResourceDictionary bucket, string key, uint rgb, byte alpha)
    {
        if (bucket.TryGetValue(key, out object? value) && value is SolidColorBrush brush)
        {
            brush.Color = Color.FromArgb(alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        }
    }
}
