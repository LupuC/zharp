using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Zharp.App;

/// <summary>Preview card model for the settings theme picker.</summary>
public sealed class ThemeCard
{
    public string Id { get; }
    public string Name { get; }
    public SolidColorBrush Bg { get; }
    public SolidColorBrush Fg { get; }
    public SolidColorBrush Accent { get; }
    public SolidColorBrush C1 { get; }
    public SolidColorBrush C2 { get; }
    public SolidColorBrush C3 { get; }
    public SolidColorBrush C4 { get; }

    private ThemeCard(ThemeSpec spec)
    {
        Id = spec.Id;
        Name = spec.Name;
        var palette = spec.CreatePalette();
        Bg = Brush(palette.DefaultBackground);
        Fg = Brush(palette.DefaultForeground);
        Accent = Brush(palette.CursorColor);
        C1 = Brush(palette.Colors[1]);  // red
        C2 = Brush(palette.Colors[2]);  // green
        C3 = Brush(palette.Colors[3]);  // yellow
        C4 = Brush(palette.Colors[4]);  // blue
    }

    public static readonly ThemeCard[] All =
        Themes.All.Select(t => new ThemeCard(t)).ToArray();

    private static SolidColorBrush Brush(uint rgb) => new(
        Color.FromArgb(0xFF, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
}
