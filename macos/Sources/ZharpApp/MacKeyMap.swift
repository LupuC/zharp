import AppKit
import ZharpCore

/// Translates AppKit key events into the virtual-key codes `TerminalInput`
/// speaks, so the VT encoding logic stays byte-identical to the Windows build.
enum MacKeyMap {

    /// The VK_* code for a key event, or 0 when the key only produces text.
    static func virtualKey(for event: NSEvent) -> Int {
        // Special keys arrive as private-use scalars in charactersIgnoringModifiers.
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey: return TerminalInput.VK_UP
            case NSDownArrowFunctionKey: return TerminalInput.VK_DOWN
            case NSLeftArrowFunctionKey: return TerminalInput.VK_LEFT
            case NSRightArrowFunctionKey: return TerminalInput.VK_RIGHT
            case NSHomeFunctionKey: return TerminalInput.VK_HOME
            case NSEndFunctionKey: return TerminalInput.VK_END
            case NSPageUpFunctionKey: return TerminalInput.VK_PRIOR
            case NSPageDownFunctionKey: return TerminalInput.VK_NEXT
            case NSInsertFunctionKey: return TerminalInput.VK_INSERT
            case NSDeleteFunctionKey: return TerminalInput.VK_DELETE
            case 0x7F: return TerminalInput.VK_BACK   // the Delete key, which sends BS
            case 0x08: return TerminalInput.VK_BACK
            case 0x0D, 0x03: return TerminalInput.VK_RETURN
            case 0x09, 0x19: return TerminalInput.VK_TAB
            case 0x1B: return TerminalInput.VK_ESCAPE
            default:
                let v = Int(scalar.value)
                if v >= NSF1FunctionKey && v <= NSF12FunctionKey {
                    return TerminalInput.VK_F1 + (v - NSF1FunctionKey)
                }
            }
        }

        // Letters, digits and the punctuation Ctrl chords need.
        if let scalar = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first {
            let v = Int(scalar.value)
            if (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) {
                return v
            }
            switch v {
            case 0x20: return 0x20 // Space
            case 0x5B: return 0xDB // [
            case 0x5C: return 0xDC // backslash
            case 0x5D: return 0xDD // ]
            case 0x2D: return 0xBD // -
            case 0x3D: return 187  // =
            case 0x2C: return 188  // ,
            case 0x2E: return 190  // .
            case 0x3B: return 186  // ;
            case 0x27: return 222  // '
            case 0x60: return 192  // `
            case 0x2F: return 191  // /
            default: break
            }
        }
        return 0
    }

    /// AppKit modifiers as the emulator's `InputModifiers`.
    ///
    /// Option is deliberately NOT reported as Alt when it is composing text
    /// (Option+e for an accent); `TerminalView` decides based on whether the
    /// event produced characters.
    static func modifiers(for event: NSEvent) -> InputModifiers {
        var mods: InputModifiers = .none
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.cmd) }
        return mods
    }
}
