import AppKit
import ZharpCore

/// One selectable color theme: chrome colors + terminal palette.
struct ThemeSpec {
    let id: String
    let name: String
    let isDark: Bool
    let chromeBackground: UInt32
    let iconColor: UInt32
    let createPalette: () -> Palette
}

/// Theme registry. Where the Windows build mutates the brushes in App.xaml's
/// theme dictionaries, here `ChromeColors` is rebuilt from the active spec and
/// every view reads its colors from `Chrome.current` on `applyTheme`.
enum Themes {
    static let all: [ThemeSpec] = [
        ThemeSpec(id: "cream", name: "Cream", isDark: false,
                  chromeBackground: 0xEDE6D8, iconColor: 0x2A2C33, createPalette: Palette.cream),
        ThemeSpec(id: "paper", name: "Paper", isDark: false,
                  chromeBackground: 0xF6F5F1, iconColor: 0x24292F, createPalette: Palette.paper),
        ThemeSpec(id: "rose", name: "Rosé", isDark: false,
                  chromeBackground: 0xFAF4ED, iconColor: 0x575279, createPalette: Palette.rose),
        ThemeSpec(id: "dark", name: "Dark", isDark: true,
                  chromeBackground: 0x282828, iconColor: 0xFFFFFF, createPalette: Palette.campbell),
        ThemeSpec(id: "navy", name: "Navy", isDark: true,
                  chromeBackground: 0x151E32, iconColor: 0xD5DEF2, createPalette: Palette.navy),
        ThemeSpec(id: "tokyo", name: "Tokyo", isDark: true,
                  chromeBackground: 0x1A1B26, iconColor: 0xC0CAF5, createPalette: Palette.tokyo),
        ThemeSpec(id: "dracula", name: "Dracula", isDark: true,
                  chromeBackground: 0x282A36, iconColor: 0xF8F8F2, createPalette: Palette.dracula),
        ThemeSpec(id: "catppuccin", name: "Catppuccin", isDark: true,
                  chromeBackground: 0x1E1E2E, iconColor: 0xCDD6F4, createPalette: Palette.catppuccin),
        ThemeSpec(id: "gruvbox", name: "Gruvbox", isDark: true,
                  chromeBackground: 0x1D2021, iconColor: 0xEBDBB2, createPalette: Palette.gruvbox),
    ]

    static func get(_ id: String?) -> ThemeSpec {
        all.first { $0.id.caseInsensitiveCompare(id ?? "") == .orderedSame } ?? all[0]
    }
}

/// The chrome brush set - the direct counterpart of App.xaml's
/// ChromeWash / PanelOverlay / Hairline / IconChip / BarIcon / SubtleIcon /
/// SectionDivider / FloatingPanel brushes.
struct ChromeColors {
    var isDark: Bool
    var chromeWash: NSColor
    var panelOverlay: NSColor
    var hairline: NSColor
    var iconChip: NSColor
    var barIcon: NSColor
    var subtleIcon: NSColor
    var sectionDivider: NSColor
    var floatingPanel: NSColor
    var text: NSColor
    var accent: NSColor
    /// Hover / selection backplates for list rows.
    var rowHover: NSColor
    var rowSelected: NSColor
    /// Brand wordmark color: cream on dark surfaces, ink on light ones.
    var brandForeground: NSColor
    /// The brand mark variant that reads on this theme's surface.
    var brandLogoName: String
    /// Update-available badge in the title bar.
    var updateBadgeBackground: NSColor
    var updateBadgeForeground: NSColor

    static func make(_ theme: ThemeSpec, backgroundOpacity: Double) -> ChromeColors {
        let washAlpha = min(max(backgroundOpacity, 100.0 / 255.0), 1.0)
        let dark = theme.isDark
        let palette = theme.createPalette()
        return ChromeColors(
            isDark: dark,
            chromeWash: rgb(theme.chromeBackground, alpha: washAlpha),
            panelOverlay: dark ? white(0, 0x28) : white(0, 0x12),
            hairline: dark ? white(0xFF, 0x16) : white(0, 0x21),
            iconChip: dark ? white(0xFF, 0x1E) : white(0, 0x14),
            barIcon: rgb(theme.iconColor, alpha: Double(0x9E) / 255.0),
            subtleIcon: rgb(theme.iconColor, alpha: Double(0x70) / 255.0),
            sectionDivider: dark ? white(0xFF, 0x1A) : white(0, 0x20),
            // Floating panels are opaque and slightly lifted from the chrome
            // color, so they stay readable over terminal text.
            floatingPanel: rgb(lift(theme.chromeBackground, toWhite: dark ? 0.06 : 0.45), alpha: 1.0),
            text: rgb(palette.defaultForeground, alpha: 1.0),
            accent: rgb(palette.cursorColor, alpha: 1.0),
            rowHover: dark ? white(0xFF, 0x14) : white(0, 0x0E),
            rowSelected: dark ? white(0xFF, 0x24) : white(0, 0x1A),
            brandForeground: rgb(dark ? 0xF0EFEC : 0x1A1A19, alpha: 1),
            brandLogoName: dark ? "logo-cream" : "logo-ink",
            // A subtle tinted pill: red enough to notice, quiet enough to live
            // in the title bar without reading as an error.
            updateBadgeBackground: dark
                ? rgb(0xE0524D, alpha: Double(0x26) / 255.0)
                : rgb(0xC4433B, alpha: Double(0x1C) / 255.0),
            updateBadgeForeground: rgb(dark ? 0xEE9C95 : 0xA8423B, alpha: 1)
        )
    }

    /// Blends an RGB color toward white by the given fraction.
    private static func lift(_ rgbValue: UInt32, toWhite: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let c = Double((rgbValue >> shift) & 0xFF)
            return UInt32(min(max(c + (255 - c) * toWhite, 0), 255))
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    static func rgb(_ value: UInt32, alpha: Double) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: CGFloat(alpha))
    }

    private static func white(_ level: UInt32, _ alpha: UInt32) -> NSColor {
        rgb(level == 0 ? 0x000000 : 0xFFFFFF, alpha: Double(alpha) / 255.0)
    }
}

/// Ambient chrome palette, read by every view when it draws.
enum Chrome {
    static var current = ChromeColors.make(Themes.all[0], backgroundOpacity: 0.94)
}
