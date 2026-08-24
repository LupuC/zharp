import Foundation

/// One tab snapshot: enough to reopen the same shell in the same place.
/// `shell` is the id from `ShellDiscovery`; empty = the configured default shell.
struct SavedSession: Codable {
    var shell = ""
    var directory = ""
}

/// User settings persisted to ~/Library/Application Support/Zharp/settings.json.
/// The key names match the Windows build byte for byte, so a settings file
/// copied between the two platforms keeps working.
final class AppSettings: Codable {

    /// Theme id: cream (default), paper, rose, dark, navy, tokyo,
    /// dracula, catppuccin, gruvbox.
    var theme = "cream"

    /// Background blur: "off", "light" (default), "medium" or "strong".
    /// The Windows names ("mica", "acrylic") are still accepted and map to the
    /// closest macOS material - see `Backdrop`.
    var backdrop = "light"

    /// Chrome/terminal background opacity, 0.5-1.0. Lower = more backdrop blur.
    var backgroundOpacity: Double = 0.94

    var isDarkTheme: Bool { Themes.get(theme).isDark }

    /// "sidebar" (vertical tab list) or "top" (horizontal strip).
    var tabLayout = "sidebar"

    /// "comfortable" (two-line cards) or "compact" (single-line).
    var sidebarDensity = "comfortable"

    /// "shell" (shell/app name as card title) or "cwd" (working directory).
    var sidebarTitleMode = "shell"

    /// Show the second line (path or shell name) on sidebar cards.
    var sidebarShowPath = true

    /// Show the tab-search box at the top of the sidebar; off shows a
    /// "Sessions" label instead.
    var sidebarShowSearch = true

    var sidebarCompact: Bool { sidebarDensity.lowercased() == "compact" }
    var sidebarTitleIsCwd: Bool { sidebarTitleMode.lowercased() == "cwd" }

    var sidebarVisible = true

    /// When true, NO_COLOR is removed from the environment of shells Zharp
    /// spawns, so tools emit ANSI colors even if it is set system-wide.
    var overrideNoColor = true

    var fontSize: Double = 13

    var fontFamily = "SF Mono"

    /// "block", "underline" or "bar" - used when apps don't set one (DECSCUSR).
    var cursorStyle = "block"

    /// "top" (classic), "bottom" (prompt hugs the bottom edge) or
    /// "pinTop" (view anchors to the prompt line, ).
    var inputPosition = "top"

    /// Maps the input-position name to TerminalView's mode code.
    static func inputPositionToCode(_ value: String?) -> Int {
        switch value?.lowercased() {
        case "bottom": return 1
        case "pintop", "pin-top": return 2
        default: return 0
        }
    }

    var scrollbackLines = 10000

    /// "auto", "zsh", "bash", "fish", "pwsh" or "sh".
    var shell = "auto"

    /// Where new terminals start. Empty = the user's home folder.
    var defaultDirectory = ""

    /// Working directory of the most recently closed terminal tab.
    var lastClosedDirectory = ""

    /// Reopen the tabs from the previous run on launch.
    var restoreSessions = true

    /// Terminal tabs open when the app last quit, in sidebar order.
    var savedSessions: [SavedSession] = []

    /// Index of the active tab within `savedSessions`.
    var savedActiveIndex = 0

    /// True once the first-run onboarding has been completed or skipped.
    var onboarded = false

    /// Website base URL serving /api/version and /download (update channel).
    var updateBaseUrl = "https://zharp.app"

    /// Version the user was last notified about, so each release notifies once.
    var lastNotifiedUpdate = ""

    /// Whole-UI zoom factor (Cmd + +/-/0), 0.7-1.5.
    var uiZoom: Double = 1.0

    var sidebarWidth: Double = 230

    /// Width of the changes panel when it is open, before UI zoom.
    var diffPanelWidth: Double = 460

    /// Height of the changed-files list inside the changes panel, before UI
    /// zoom. Null until the divider is dragged: up to that point the list
    /// sizes itself to how many files there are, which is the better default.
    var diffListHeight: Double? = nil

    /// Rebindable shortcuts: action id -> "Cmd+Shift+T"-style binding.
    var keybindings: [String: String] = [:]

    var useSidebar: Bool { tabLayout.lowercased() != "top" }

    /// Maps the cursor style name to its DECSCUSR-style code.
    static func cursorStyleToCode(_ style: String?) -> Int {
        switch style?.lowercased() {
        case "underline": return 3
        case "bar": return 5
        default: return 0
        }
    }

    // ---------------------------------------------------------------- storage

    /// ~/Library/Application Support/Zharp - the macOS counterpart of
    /// %LOCALAPPDATA%\Zharp.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Zharp", isDirectory: true)
    }

    static var settingsURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: settingsURL)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Missing or corrupt settings fall back to defaults.
            return AppSettings()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.settingsURL, options: .atomic)
        } catch {
            // Non-fatal: settings just won't persist.
        }
    }

    init() {}

    // Hand-rolled coding so a settings file missing keys (or written by an
    // older build) still loads, exactly like the Windows JSON deserializer.
    private enum CodingKeys: String, CodingKey {
        case theme, backdrop, backgroundOpacity, tabLayout, sidebarDensity
        case sidebarTitleMode, sidebarShowPath, sidebarShowSearch
        case sidebarVisible, overrideNoColor
        case restoreSessions, savedSessions, savedActiveIndex
        case fontSize, fontFamily, cursorStyle, inputPosition, scrollbackLines
        case shell, defaultDirectory, lastClosedDirectory, onboarded
        case updateBaseUrl, lastNotifiedUpdate, uiZoom, sidebarWidth
        case diffPanelWidth, diffListHeight, keybindings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ key: CodingKeys, _ fallback: String) -> String {
            (try? c.decodeIfPresent(String.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        func d(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        func i(_ key: CodingKeys, _ fallback: Int) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        func b(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? fallback
        }

        theme = s(.theme, "cream")
        backdrop = s(.backdrop, "light")
        backgroundOpacity = d(.backgroundOpacity, 0.94)
        tabLayout = s(.tabLayout, "sidebar")
        sidebarDensity = s(.sidebarDensity, "comfortable")
        sidebarTitleMode = s(.sidebarTitleMode, "shell")
        sidebarShowPath = b(.sidebarShowPath, true)
        sidebarShowSearch = b(.sidebarShowSearch, true)
        sidebarVisible = b(.sidebarVisible, true)
        overrideNoColor = b(.overrideNoColor, true)
        fontSize = d(.fontSize, 13)
        fontFamily = s(.fontFamily, "SF Mono")
        cursorStyle = s(.cursorStyle, "block")
        inputPosition = s(.inputPosition, "top")
        scrollbackLines = i(.scrollbackLines, 10000)
        shell = s(.shell, "auto")
        defaultDirectory = s(.defaultDirectory, "")
        lastClosedDirectory = s(.lastClosedDirectory, "")
        restoreSessions = b(.restoreSessions, true)
        savedSessions = (try? c.decodeIfPresent([SavedSession].self, forKey: .savedSessions))
            .flatMap { $0 } ?? []
        savedActiveIndex = i(.savedActiveIndex, 0)
        onboarded = b(.onboarded, false)
        updateBaseUrl = s(.updateBaseUrl, "https://zharp.app")
        lastNotifiedUpdate = s(.lastNotifiedUpdate, "")
        uiZoom = d(.uiZoom, 1.0)
        sidebarWidth = d(.sidebarWidth, 230)
        diffPanelWidth = d(.diffPanelWidth, 460)
        diffListHeight = try? c.decodeIfPresent(Double.self, forKey: .diffListHeight)
        keybindings = (try? c.decodeIfPresent([String: String].self, forKey: .keybindings))
            .flatMap { $0 } ?? [:]
    }
}
