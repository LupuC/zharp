import Foundation

public struct InputModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let none  = InputModifiers([])
    public static let shift = InputModifiers(rawValue: 1)
    public static let alt   = InputModifiers(rawValue: 2)
    public static let ctrl  = InputModifiers(rawValue: 4)
    /// macOS Command key. Never reaches the shell - it drives app shortcuts.
    public static let cmd   = InputModifiers(rawValue: 8)
}

/// Encodes non-character keys (arrows, function keys, editing keys) into the
/// VT sequences a terminal application expects.
///
/// Key codes are the same virtual-key values the Windows build uses (VK_*),
/// so this encoder stays byte-for-byte identical across the two platforms;
/// `MacKeyMap` translates AppKit key codes into them.
public enum TerminalInput {
    public static let VK_BACK = 0x08
    public static let VK_TAB = 0x09
    public static let VK_RETURN = 0x0D
    public static let VK_ESCAPE = 0x1B
    public static let VK_SPACE = 0x20
    public static let VK_PRIOR = 0x21
    public static let VK_NEXT = 0x22
    public static let VK_END = 0x23
    public static let VK_HOME = 0x24
    public static let VK_LEFT = 0x25
    public static let VK_UP = 0x26
    public static let VK_RIGHT = 0x27
    public static let VK_DOWN = 0x28
    public static let VK_INSERT = 0x2D
    public static let VK_DELETE = 0x2E
    public static let VK_F1 = 0x70

    /// Returns the escape sequence for a key press, or nil when the key should
    /// instead be handled through normal character input.
    public static func encodeKey(virtualKey: Int, mods: InputModifiers,
                                 applicationCursorKeys: Bool) -> String? {
        let modCode = 1
            + (mods.contains(.shift) ? 1 : 0)
            + (mods.contains(.alt) ? 2 : 0)
            + (mods.contains(.ctrl) ? 4 : 0)
        let hasMods = modCode > 1

        switch virtualKey {
        case VK_RETURN:
            return mods.contains(.alt) ? "\u{1b}\r" : "\r"
        case VK_ESCAPE:
            return "\u{1b}"
        case VK_BACK:
            if mods.contains(.ctrl) {
                return mods.contains(.alt) ? "\u{1b}\u{8}" : "\u{8}"
            }
            return mods.contains(.alt) ? "\u{1b}\u{7f}" : "\u{7f}"
        case VK_TAB:
            return mods.contains(.shift) ? "\u{1b}[Z" : "\t"

        case VK_UP:    return cursorKey("A", hasMods, modCode, applicationCursorKeys)
        case VK_DOWN:  return cursorKey("B", hasMods, modCode, applicationCursorKeys)
        case VK_RIGHT: return cursorKey("C", hasMods, modCode, applicationCursorKeys)
        case VK_LEFT:  return cursorKey("D", hasMods, modCode, applicationCursorKeys)
        case VK_HOME:  return cursorKey("H", hasMods, modCode, applicationCursorKeys)
        case VK_END:   return cursorKey("F", hasMods, modCode, applicationCursorKeys)

        case VK_INSERT: return tildeKey(2, hasMods, modCode)
        case VK_DELETE: return tildeKey(3, hasMods, modCode)
        case VK_PRIOR:  return tildeKey(5, hasMods, modCode)
        case VK_NEXT:   return tildeKey(6, hasMods, modCode)
        default: break
        }

        // Function keys F1..F12
        if virtualKey >= VK_F1 && virtualKey <= VK_F1 + 11 {
            let f = virtualKey - VK_F1 + 1
            if f <= 4 {
                let final = Character(UnicodeScalar(UInt8(0x50 + f - 1))) // 'P'..'S'
                return hasMods ? "\u{1b}[1;\(modCode)\(final)" : "\u{1b}O\(final)"
            }
            let code: Int
            switch f {
            case 5: code = 15
            case 6: code = 17
            case 7: code = 18
            case 8: code = 19
            case 9: code = 20
            case 10: code = 21
            case 11: code = 23
            case 12: code = 24
            default: code = 0
            }
            return tildeKey(code, hasMods, modCode)
        }

        return nil
    }

    private static func cursorKey(_ final: Character, _ hasMods: Bool,
                                  _ modCode: Int, _ appMode: Bool) -> String {
        if hasMods { return "\u{1b}[1;\(modCode)\(final)" }
        return appMode ? "\u{1b}O\(final)" : "\u{1b}[\(final)"
    }

    private static func tildeKey(_ code: Int, _ hasMods: Bool, _ modCode: Int) -> String {
        hasMods ? "\u{1b}[\(code);\(modCode)~" : "\u{1b}[\(code)~"
    }

    /// Control-key chord to control character (Ctrl+A -> 0x01 ...), or nil.
    public static func encodeControlChord(virtualKey: Int, mods: InputModifiers) -> String? {
        if !mods.contains(.ctrl) || mods.contains(.alt) { return nil }

        // Letters
        if virtualKey >= 0x41 && virtualKey <= 0x5A { // 'A'..'Z'
            return String(UnicodeScalar(UInt8(virtualKey - 0x41 + 1)))
        }

        switch virtualKey {
        case 0x20: return "\u{0}"    // Ctrl+Space
        case 0xDB: return "\u{1b}"   // Ctrl+[
        case 0xDC: return "\u{1c}"   // Ctrl+\
        case 0xDD: return "\u{1d}"   // Ctrl+]
        case 0x32: return "\u{0}"    // Ctrl+2 -> NUL
        case 0x36: return "\u{1e}"   // Ctrl+6 -> RS
        case 0xBD: return "\u{1f}"   // Ctrl+- -> US
        default: return nil
        }
    }
}
