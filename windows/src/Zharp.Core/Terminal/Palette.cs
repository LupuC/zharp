namespace Zharp.Core.Terminal;

/// <summary>
/// Color scheme: 256-entry indexed palette plus default foreground/background.
/// Colors are 0xRRGGBB.
/// </summary>
public sealed class Palette
{
    public uint[] Colors { get; } = new uint[256];
    public uint DefaultForeground { get; set; }
    public uint DefaultBackground { get; set; }
    public uint CursorColor { get; set; }
    public uint SelectionColor { get; set; }

    /// <summary>
    /// Campbell ANSI colors on a soft dark-grey surface (not pure black),
    /// with a blue accent cursor.
    /// </summary>
    public static Palette Campbell()
    {
        var p = new Palette
        {
            DefaultForeground = 0xCFCFCF,
            DefaultBackground = 0x282828,
            CursorColor = 0x7AA2F7,
            SelectionColor = 0xFFFFFF,
        };
        uint[] ansi =
        {
            0x0C0C0C, 0xC50F1F, 0x13A10E, 0xC19C00, 0x0037DA, 0x881798, 0x3A96DD, 0xCCCCCC,
            0x767676, 0xE74856, 0x16C60C, 0xF9F1A5, 0x3B78FF, 0xB4009E, 0x61D6D6, 0xF2F2F2,
        };
        Array.Copy(ansi, p.Colors, 16);

        // 6x6x6 color cube (16..231)
        int[] steps = { 0, 95, 135, 175, 215, 255 };
        for (int r = 0; r < 6; r++)
            for (int g = 0; g < 6; g++)
                for (int b = 0; b < 6; b++)
                    p.Colors[16 + r * 36 + g * 6 + b] =
                        (uint)(steps[r] << 16 | steps[g] << 8 | steps[b]);

        // Grayscale ramp (232..255)
        for (int i = 0; i < 24; i++)
        {
            int v = 8 + i * 10;
            p.Colors[232 + i] = (uint)(v << 16 | v << 8 | v);
        }
        return p;
    }

    private static Palette Build(uint fg, uint bg, uint cursor, uint selection, uint[] ansi16)
    {
        var p = Campbell(); // reuse the 256-cube and grayscale ramp
        p.DefaultForeground = fg;
        p.DefaultBackground = bg;
        p.CursorColor = cursor;
        p.SelectionColor = selection;
        Array.Copy(ansi16, p.Colors, 16);
        return p;
    }

    private static readonly uint[] GitHubLightAnsi =
    {
        0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C8C, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    };

    /// <summary>
    /// Cream - a warm light scheme built around Zharp's logo color:
    /// charcoal text on a cream surface, ANSI colors tuned for light backgrounds.
    /// </summary>
    public static Palette Cream() =>
        Build(0x23262D, 0xEDE6D8, 0x3B5BDB, 0x33415C, GitHubLightAnsi);

    /// <summary>Paper - clean neutral light scheme.</summary>
    public static Palette Paper() =>
        Build(0x24292F, 0xF6F5F1, 0x0969DA, 0x0969DA, GitHubLightAnsi);

    /// <summary>Rosé - warm light scheme after Rosé Pine Dawn.</summary>
    public static Palette Rose() => Build(0x575279, 0xFAF4ED, 0xB4637A, 0x907AA9, new uint[]
    {
        0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
        0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
    });

    /// <summary>Navy - deep blue dark scheme (the logo's navy), Nord-flavored ANSI.</summary>
    public static Palette Navy() => Build(0xC7D1E8, 0x151E32, 0x6E9BFF, 0xFFFFFF, new uint[]
    {
        0x1C2540, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xD8DEE9,
        0x4C566A, 0xD07079, 0xB1CC97, 0xF0D399, 0x8FB0D3, 0xC29DBF, 0x93CEDE, 0xECEFF4,
    });

    /// <summary>Tokyo - indigo dark scheme after Tokyo Night.</summary>
    public static Palette Tokyo() => Build(0xC0CAF5, 0x1A1B26, 0x7AA2F7, 0xFFFFFF, new uint[]
    {
        0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
        0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
    });

    /// <summary>Dracula - purple-tinted dark scheme (draculatheme.com spec).</summary>
    public static Palette Dracula() => Build(0xF8F8F2, 0x282A36, 0xBD93F9, 0xFFFFFF, new uint[]
    {
        0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
        0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    });

    /// <summary>Catppuccin - soft pastel dark scheme (Mocha flavor).</summary>
    public static Palette Catppuccin() => Build(0xCDD6F4, 0x1E1E2E, 0xF5E0DC, 0xFFFFFF, new uint[]
    {
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
        0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xCDD6F4,
    });

    /// <summary>Gruvbox - warm retro dark scheme (hard-contrast background).</summary>
    public static Palette Gruvbox() => Build(0xEBDBB2, 0x1D2021, 0xFE8019, 0xFFFFFF, new uint[]
    {
        0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    });

    /// <summary>
    /// Resolves a cell's effective colors, applying bold-brightening, inverse,
    /// dim and hidden. <paramref name="bgIsDefault"/> is true when the cell
    /// background is the scheme default (lets the renderer keep it translucent).
    /// </summary>
    public void Resolve(in Cell cell, out uint fg, out uint bg, out bool bgIsDefault)
    {
        fg = ResolveColor(cell.Fg, isForeground: true, bold: (cell.Flags & CellFlags.Bold) != 0);
        bg = ResolveColor(cell.Bg, isForeground: false, bold: false);
        bgIsDefault = cell.Bg.IsDefault;

        if ((cell.Flags & CellFlags.Inverse) != 0)
        {
            (fg, bg) = (bg, fg);
            bgIsDefault = false;
        }

        if ((cell.Flags & CellFlags.Dim) != 0)
            fg = (fg >> 1) & 0x7F7F7F;

        if ((cell.Flags & CellFlags.Hidden) != 0)
            fg = bg;
    }

    public uint ResolveColor(TerminalColor color, bool isForeground, bool bold)
    {
        if (color.IsDefault)
            return isForeground ? DefaultForeground : DefaultBackground;
        if (color.IsIndexed)
        {
            int idx = color.Index;
            if (bold && idx < 8)
                idx += 8; // classic bold-as-bright
            return Colors[idx];
        }
        return color.RgbValue;
    }
}
