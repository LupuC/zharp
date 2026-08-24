import AppKit

/// Tabler Icons v3.46 (MIT) - https://tabler.io/icons - bundled as a webfont,
/// the same file and the same code points the Windows build uses. The font is
/// subset to just the glyphs the app draws and rebuilt at a 1.25px stroke, so
/// it weighs 9KB rather than 2.8MB and reads lighter at small sizes.
enum Icons {
    static let sidebar    = "\u{EADA}" // layout-sidebar
    static let settings   = "\u{EB20}" // settings
    static let search     = "\u{EB1C}" // search
    static let plus       = "\u{EB0B}" // plus
    static let close      = "\u{EB55}" // x
    static let terminal2  = "\u{EBEF}" // terminal-2
    static let terminal   = "\u{EBDC}" // terminal
    static let prompt     = "\u{EB0F}" // prompt
    static let palette    = "\u{EB01}" // palette
    static let keyboard   = "\u{EBD6}" // keyboard
    static let info       = "\u{EAC5}" // info-circle
    static let check      = "\u{EA67}" // check
    static let copy       = "\u{EA7A}" // copy
    static let fileDiff   = "\u{ECF1}" // file-diff
    static let refresh    = "\u{EB13}" // refresh
    static let powershell = "\u{F5ED}" // brand-powershell
    static let git        = "\u{EF6F}" // brand-git
    static let ubuntu     = "\u{EF59}" // brand-ubuntu

    private static var registered = false

    /// Registers the bundled webfonts with Core Text so `font(size:)` and the
    /// brand font resolve.
    static func registerFont() {
        if registered { return }
        registered = true
        for name in ["tabler-icons", "DMMono-Medium"] {
            guard let url = Resources.url(forResource: name, withExtension: "ttf") else {
                App.log("\(name).ttf missing from the bundle")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                App.log("Registering \(name).ttf failed: \(String(describing: error))")
            }
        }
    }

    static func font(size: CGFloat) -> NSFont {
        registerFont()
        return NSFont(name: "tabler-icons", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    /// DM Mono, the brand's monospace face - used for the wordmark and the
    /// version line in the sidebar footer, not for terminal text.
    static func brandFont(size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        registerFont()
        return NSFont(name: "DMMono-Medium", size: size)
            ?? NSFont(name: "DM Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Glyph for a shell id, mirroring the Windows new-tab menu. The subset
    /// carries no fish mark, so fish falls back to the generic terminal glyph.
    static func shellGlyph(_ shellId: String) -> String {
        switch shellId {
        case "pwsh": return powershell
        case "sh": return prompt
        case "zsh", "bash", "fish": return terminal
        default: return terminal
        }
    }
}

/// An AI coding agent Zharp recognizes running inside a session.
struct AgentKind {
    /// Matched case-insensitively against the shell-reported title and the
    /// last command.
    let match: String
    let name: String
    let glyph: String
    let color: NSColor

    /// The agents the Windows build knows, with the same glyphs and colors.
    static let all: [AgentKind] = [
        AgentKind(match: "claude", name: "Claude Code", glyph: "\u{F8F0}",
                  color: ChromeColors.rgb(0xD97757, alpha: 1)),
        AgentKind(match: "opencode", name: "OpenCode", glyph: "\u{F8F3}",
                  color: ChromeColors.rgb(0x7C8CF8, alpha: 1)),
        AgentKind(match: "codex", name: "Codex", glyph: "\u{F78E}",
                  color: ChromeColors.rgb(0x74AA9C, alpha: 1)),
        AgentKind(match: "gemini", name: "Gemini CLI", glyph: "\u{F8F2}",
                  color: ChromeColors.rgb(0x4E86F7, alpha: 1)),
        AgentKind(match: "aider", name: "Aider", glyph: "\u{EFD5}",
                  color: ChromeColors.rgb(0x00A67D, alpha: 1)),
    ]

    /// The agent a title or command names, or nil.
    static func detect(in text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        for (index, agent) in all.enumerated()
        where text.range(of: agent.match, options: .caseInsensitive) != nil {
            return index
        }
        return nil
    }
}
