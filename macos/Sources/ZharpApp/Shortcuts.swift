import AppKit

/// A rebindable application action.
struct ShortcutAction {
    let id: String
    let displayName: String
    let defaultBinding: String
}

/// The app's rebindable shortcuts: defaults, parsing "Cmd+Shift+T"-style
/// binding strings, and formatting captured key combinations back into them.
///
/// The action ids match the Windows build; the default bindings use Command,
/// because on macOS Control belongs to the shell (Ctrl+C must interrupt, not
/// open a tab).
enum Shortcuts {
    static let actions: [ShortcutAction] = [
        ShortcutAction(id: "newTab", displayName: "New session", defaultBinding: "Cmd+T"),
        ShortcutAction(id: "closeTab", displayName: "Close session", defaultBinding: "Cmd+W"),
        ShortcutAction(id: "nextTab", displayName: "Next session", defaultBinding: "Ctrl+Tab"),
        ShortcutAction(id: "prevTab", displayName: "Previous session", defaultBinding: "Ctrl+Shift+Tab"),
        ShortcutAction(id: "toggleSidebar", displayName: "Toggle tab panel", defaultBinding: "Cmd+B"),
        ShortcutAction(id: "openSettings", displayName: "Open settings", defaultBinding: "Cmd+,"),
        ShortcutAction(id: "toggleSearch", displayName: "Toggle search", defaultBinding: "Cmd+Shift+F"),
        ShortcutAction(id: "zoomIn", displayName: "Zoom in", defaultBinding: "Cmd+="),
        ShortcutAction(id: "zoomOut", displayName: "Zoom out", defaultBinding: "Cmd+-"),
        ShortcutAction(id: "zoomReset", displayName: "Reset zoom", defaultBinding: "Cmd+0"),
        ShortcutAction(id: "copy", displayName: "Copy selection", defaultBinding: "Cmd+C"),
        ShortcutAction(id: "paste", displayName: "Paste", defaultBinding: "Cmd+V"),
        ShortcutAction(id: "blockPrev", displayName: "Previous block", defaultBinding: "Cmd+Up"),
        ShortcutAction(id: "blockNext", displayName: "Next block", defaultBinding: "Cmd+Down"),
        ShortcutAction(id: "copyOutput", displayName: "Copy block output",
                       defaultBinding: "Cmd+Shift+O"),
        ShortcutAction(id: "findInBlock", displayName: "Find within block",
                       defaultBinding: "Cmd+Shift+G"),
    ]

    /// Actions handled inside the focused terminal (block actions): they are
    /// rebindable but not registered as window-level shortcuts, so they can fall
    /// through to the shell when no blocks exist.
    static func isTerminalScope(_ actionId: String) -> Bool {
        ["blockPrev", "blockNext", "copyOutput", "findInBlock"].contains(actionId)
    }

    /// The user's binding for an action, falling back to the default.
    static func binding(_ settings: AppSettings, _ actionId: String) -> String {
        if let binding = settings.keybindings[actionId],
           !binding.trimmingCharacters(in: .whitespaces).isEmpty {
            return binding
        }
        return actions.first { $0.id == actionId }?.defaultBinding ?? ""
    }

    /// Punctuation keys that have no friendly virtual-key name.
    private static let specialKeys: [(name: String, vk: Int)] = [
        ("=", 187), ("-", 189), (",", 188), (".", 190), (";", 186),
        ("'", 222), ("[", 219), ("]", 221), ("\\", 220), ("`", 192), ("/", 191),
    ]

    struct Combo: Equatable {
        var modifiers: NSEvent.ModifierFlags
        var virtualKey: Int

        static func == (a: Combo, b: Combo) -> Bool {
            a.virtualKey == b.virtualKey
                && a.modifiers.intersection(.deviceIndependentFlagsMask)
                    == b.modifiers.intersection(.deviceIndependentFlagsMask)
        }
    }

    static func parse(_ binding: String) -> Combo? {
        if binding.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        // A trailing "+" key (e.g. "Cmd++") would confuse the split; bindings
        // spell that key "=" instead.
        let parts = binding.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: NSEvent.ModifierFlags = []
        var virtualKey = 0

        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            if !isLast {
                switch part.lowercased() {
                case "cmd", "command": modifiers.insert(.command); continue
                case "ctrl", "control": modifiers.insert(.control); continue
                case "shift": modifiers.insert(.shift); continue
                case "alt", "option", "opt": modifiers.insert(.option); continue
                default: return nil
                }
            }
            virtualKey = parseKey(part)
        }
        return virtualKey != 0 ? Combo(modifiers: modifiers, virtualKey: virtualKey) : nil
    }

    private static func parseKey(_ token: String) -> Int {
        if token.count == 1 {
            let c = Character(token.uppercased())
            if (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") {
                return Int(c.unicodeScalars.first!.value)
            }
            for (name, vk) in specialKeys where name == token {
                return vk
            }
            return 0
        }
        if token.count >= 2, token.lowercased().hasPrefix("f"),
           let f = Int(token.dropFirst()), (1...24).contains(f) {
            return 0x70 + f - 1
        }
        switch token.lowercased() {
        case "tab": return 0x09
        case "space": return 0x20
        case "enter", "return": return 0x0D
        case "escape", "esc": return 0x1B
        case "pageup": return 0x21
        case "pagedown": return 0x22
        case "end": return 0x23
        case "home": return 0x24
        case "left": return 0x25
        case "up": return 0x26
        case "right": return 0x27
        case "down": return 0x28
        case "insert": return 0x2D
        case "delete": return 0x2E
        default: return 0
        }
    }

    /// Formats a captured combination, or nil if the key is unsupported.
    static func format(modifiers: NSEvent.ModifierFlags, virtualKey: Int) -> String? {
        guard let key = formatKey(virtualKey) else { return nil }
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.option) { parts.append("Alt") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func formatKey(_ vk: Int) -> String? {
        if (vk >= 0x41 && vk <= 0x5A) || (vk >= 0x30 && vk <= 0x39) {
            return String(UnicodeScalar(UInt8(vk)))
        }
        for (name, special) in specialKeys where special == vk {
            return name
        }
        if vk >= 0x70 && vk <= 0x87 {
            return "F\(vk - 0x70 + 1)"
        }
        switch vk {
        case 0x09: return "Tab"
        case 0x20: return "Space"
        case 0x0D: return "Enter"
        case 0x1B: return "Escape"
        case 0x21: return "PageUp"
        case 0x22: return "PageDown"
        case 0x23: return "End"
        case 0x24: return "Home"
        case 0x25: return "Left"
        case 0x26: return "Up"
        case 0x27: return "Right"
        case 0x28: return "Down"
        case 0x2D: return "Insert"
        case 0x2E: return "Delete"
        default: return nil
        }
    }

    /// The `keyEquivalent` string an NSMenuItem wants for a virtual key.
    static func keyEquivalent(for vk: Int) -> String {
        switch vk {
        case 0x26: return "\u{F700}" // Up
        case 0x28: return "\u{F701}" // Down
        case 0x25: return "\u{F702}" // Left
        case 0x27: return "\u{F703}" // Right
        case 0x09: return "\t"
        case 0x0D: return "\r"
        case 0x1B: return "\u{1b}"
        default:
            return (formatKey(vk) ?? "").lowercased()
        }
    }

    /// Renders a binding using the symbols macOS users read in menus
    /// ("Cmd+Shift+F" -> "⇧⌘F"), for the settings and onboarding key chips.
    static func symbolic(_ binding: String) -> String {
        guard let combo = parse(binding) else { return binding }
        var out = ""
        if combo.modifiers.contains(.control) { out += "⌃" }
        if combo.modifiers.contains(.option) { out += "⌥" }
        if combo.modifiers.contains(.shift) { out += "⇧" }
        if combo.modifiers.contains(.command) { out += "⌘" }
        out += formatKey(combo.virtualKey) ?? ""
        return out
    }
}
