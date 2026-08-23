import Foundation

/// Color scheme: 256-entry indexed palette plus default foreground/background.
/// Colors are 0xRRGGBB.
public final class Palette {
    public var colors = [UInt32](repeating: 0, count: 256)
    public var defaultForeground: UInt32 = 0
    public var defaultBackground: UInt32 = 0
    public var cursorColor: UInt32 = 0
    public var selectionColor: UInt32 = 0

    public init() {}

    /// Campbell ANSI colors on a soft dark-grey surface (not pure black),
    /// with a blue accent cursor.
    public static func campbell() -> Palette {
        let p = Palette()
        p.defaultForeground = 0xCFCFCF
        p.defaultBackground = 0x282828
        p.cursorColor = 0x7AA2F7
        p.selectionColor = 0xFFFFFF

        let ansi: [UInt32] = [
            0x0C0C0C, 0xC50F1F, 0x13A10E, 0xC19C00, 0x0037DA, 0x881798, 0x3A96DD, 0xCCCCCC,
            0x767676, 0xE74856, 0x16C60C, 0xF9F1A5, 0x3B78FF, 0xB4009E, 0x61D6D6, 0xF2F2F2,
        ]
        for i in 0..<16 { p.colors[i] = ansi[i] }

        // 6x6x6 color cube (16..231)
        let steps = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    p.colors[16 + r * 36 + g * 6 + b] =
                        UInt32((steps[r] << 16) | (steps[g] << 8) | steps[b])
                }
            }
        }

        // Grayscale ramp (232..255)
        for i in 0..<24 {
            let v = 8 + i * 10
            p.colors[232 + i] = UInt32((v << 16) | (v << 8) | v)
        }
        return p
    }

    private static func build(fg: UInt32, bg: UInt32, cursor: UInt32,
                              selection: UInt32, ansi16: [UInt32]) -> Palette {
        let p = campbell() // reuse the 256-cube and grayscale ramp
        p.defaultForeground = fg
        p.defaultBackground = bg
        p.cursorColor = cursor
        p.selectionColor = selection
        for i in 0..<min(16, ansi16.count) { p.colors[i] = ansi16[i] }
        return p
    }

    private static let gitHubLightAnsi: [UInt32] = [
        0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C8C, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ]

    /// Cream - a warm light scheme built around Zharp's logo color:
    /// charcoal text on a cream surface, ANSI colors tuned for light backgrounds.
    public static func cream() -> Palette {
        build(fg: 0x23262D, bg: 0xEDE6D8, cursor: 0x3B5BDB, selection: 0x33415C, ansi16: gitHubLightAnsi)
    }

    /// Paper - clean neutral light scheme.
    public static func paper() -> Palette {
        build(fg: 0x24292F, bg: 0xF6F5F1, cursor: 0x0969DA, selection: 0x0969DA, ansi16: gitHubLightAnsi)
    }

    /// Rosé - warm light scheme after Rosé Pine Dawn.
    public static func rose() -> Palette {
        build(fg: 0x575279, bg: 0xFAF4ED, cursor: 0xB4637A, selection: 0x907AA9, ansi16: [
            0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
            0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
        ])
    }

    /// Navy - deep blue dark scheme (the logo's navy), Nord-flavored ANSI.
    public static func navy() -> Palette {
        build(fg: 0xC7D1E8, bg: 0x151E32, cursor: 0x6E9BFF, selection: 0xFFFFFF, ansi16: [
            0x1C2540, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xD8DEE9,
            0x4C566A, 0xD07079, 0xB1CC97, 0xF0D399, 0x8FB0D3, 0xC29DBF, 0x93CEDE, 0xECEFF4,
        ])
    }

    /// Tokyo - indigo dark scheme after Tokyo Night.
    public static func tokyo() -> Palette {
        build(fg: 0xC0CAF5, bg: 0x1A1B26, cursor: 0x7AA2F7, selection: 0xFFFFFF, ansi16: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
        ])
    }

    /// Dracula - purple-tinted dark scheme (draculatheme.com spec).
    public static func dracula() -> Palette {
        build(fg: 0xF8F8F2, bg: 0x282A36, cursor: 0xBD93F9, selection: 0xFFFFFF, ansi16: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ])
    }

    /// Catppuccin - soft pastel dark scheme (Mocha flavor).
    public static func catppuccin() -> Palette {
        build(fg: 0xCDD6F4, bg: 0x1E1E2E, cursor: 0xF5E0DC, selection: 0xFFFFFF, ansi16: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xCDD6F4,
        ])
    }

    /// Gruvbox - warm retro dark scheme (hard-contrast background).
    public static func gruvbox() -> Palette {
        build(fg: 0xEBDBB2, bg: 0x1D2021, cursor: 0xFE8019, selection: 0xFFFFFF, ansi16: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ])
    }

    /// Resolved colors for one cell, after bold-brightening, inverse, dim and
    /// hidden. `bgIsDefault` is true when the cell background is the scheme
    /// default (lets the renderer keep it translucent).
    public struct Resolved {
        public var fg: UInt32
        public var bg: UInt32
        public var bgIsDefault: Bool
    }

    public func resolve(_ cell: Cell) -> Resolved {
        var fg = resolveColor(cell.fg, isForeground: true, bold: cell.flags.contains(.bold))
        var bg = resolveColor(cell.bg, isForeground: false, bold: false)
        var bgIsDefault = cell.bg.isDefault

        if cell.flags.contains(.inverse) {
            swap(&fg, &bg)
            bgIsDefault = false
        }
        if cell.flags.contains(.dim) {
            fg = (fg >> 1) & 0x7F7F7F
        }
        if cell.flags.contains(.hidden) {
            fg = bg
        }
        return Resolved(fg: fg, bg: bg, bgIsDefault: bgIsDefault)
    }

    public func resolveColor(_ color: TerminalColor, isForeground: Bool, bold: Bool) -> UInt32 {
        if color.isDefault {
            return isForeground ? defaultForeground : defaultBackground
        }
        if color.isIndexed {
            var idx = color.index
            if bold && idx < 8 { idx += 8 } // classic bold-as-bright
            return colors[idx]
        }
        return color.rgbValue
    }
}
