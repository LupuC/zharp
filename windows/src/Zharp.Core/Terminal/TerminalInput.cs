namespace Zharp.Core.Terminal;

[Flags]
public enum InputModifiers
{
    None = 0,
    Shift = 1,
    Alt = 2,
    Ctrl = 4,
}

/// <summary>
/// Encodes non-character keys (arrows, function keys, editing keys) into the
/// VT sequences a terminal application expects. Virtual-key codes are the
/// standard Windows VK_* values.
/// </summary>
public static class TerminalInput
{
    private const int VK_BACK = 0x08;
    private const int VK_TAB = 0x09;
    private const int VK_RETURN = 0x0D;
    private const int VK_ESCAPE = 0x1B;
    private const int VK_PRIOR = 0x21;
    private const int VK_NEXT = 0x22;
    private const int VK_END = 0x23;
    private const int VK_HOME = 0x24;
    private const int VK_LEFT = 0x25;
    private const int VK_UP = 0x26;
    private const int VK_RIGHT = 0x27;
    private const int VK_DOWN = 0x28;
    private const int VK_INSERT = 0x2D;
    private const int VK_DELETE = 0x2E;
    private const int VK_F1 = 0x70;

    /// <summary>
    /// Returns the escape sequence for a key press, or null when the key should
    /// instead be handled through normal character input.
    /// </summary>
    public static string? EncodeKey(int virtualKey, InputModifiers mods, bool applicationCursorKeys)
    {
        int modCode = 1
            + ((mods & InputModifiers.Shift) != 0 ? 1 : 0)
            + ((mods & InputModifiers.Alt) != 0 ? 2 : 0)
            + ((mods & InputModifiers.Ctrl) != 0 ? 4 : 0);
        bool hasMods = modCode > 1;

        switch (virtualKey)
        {
            case VK_RETURN:
                return (mods & InputModifiers.Alt) != 0 ? "\x1b\r" : "\r";
            case VK_ESCAPE:
                return "\x1b";
            case VK_BACK:
                if ((mods & InputModifiers.Ctrl) != 0)
                    return (mods & InputModifiers.Alt) != 0 ? "\x1b\b" : "\b";
                return (mods & InputModifiers.Alt) != 0 ? "\x1b\x7f" : "\x7f";
            case VK_TAB:
                return (mods & InputModifiers.Shift) != 0 ? "\x1b[Z" : "\t";

            case VK_UP: return CursorKey('A', hasMods, modCode, applicationCursorKeys);
            case VK_DOWN: return CursorKey('B', hasMods, modCode, applicationCursorKeys);
            case VK_RIGHT: return CursorKey('C', hasMods, modCode, applicationCursorKeys);
            case VK_LEFT: return CursorKey('D', hasMods, modCode, applicationCursorKeys);
            case VK_HOME: return CursorKey('H', hasMods, modCode, applicationCursorKeys);
            case VK_END: return CursorKey('F', hasMods, modCode, applicationCursorKeys);

            case VK_INSERT: return TildeKey(2, hasMods, modCode);
            case VK_DELETE: return TildeKey(3, hasMods, modCode);
            case VK_PRIOR: return TildeKey(5, hasMods, modCode);
            case VK_NEXT: return TildeKey(6, hasMods, modCode);
        }

        // Function keys F1..F12
        if (virtualKey >= VK_F1 && virtualKey <= VK_F1 + 11)
        {
            int f = virtualKey - VK_F1 + 1;
            if (f <= 4)
            {
                char final = (char)('P' + f - 1);
                return hasMods ? $"\x1b[1;{modCode}{final}" : $"\x1bO{final}";
            }
            int code = f switch
            {
                5 => 15,
                6 => 17,
                7 => 18,
                8 => 19,
                9 => 20,
                10 => 21,
                11 => 23,
                12 => 24,
                _ => 0,
            };
            return TildeKey(code, hasMods, modCode);
        }

        return null;
    }

    private static string CursorKey(char final, bool hasMods, int modCode, bool appMode)
    {
        if (hasMods)
            return $"\x1b[1;{modCode}{final}";
        return appMode ? $"\x1bO{final}" : $"\x1b[{final}";
    }

    private static string TildeKey(int code, bool hasMods, int modCode) =>
        hasMods ? $"\x1b[{code};{modCode}~" : $"\x1b[{code}~";

    /// <summary>Control-key chord to control character (Ctrl+A → 0x01 …), or null.</summary>
    public static string? EncodeControlChord(int virtualKey, InputModifiers mods)
    {
        if ((mods & InputModifiers.Ctrl) == 0 || (mods & InputModifiers.Alt) != 0)
            return null;

        // Letters
        if (virtualKey >= 'A' && virtualKey <= 'Z')
            return ((char)(virtualKey - 'A' + 1)).ToString();

        return virtualKey switch
        {
            0x20 => "\x00",       // Ctrl+Space
            0xDB => "\x1b",       // Ctrl+[
            0xDC => "\x1c",       // Ctrl+\
            0xDD => "\x1d",       // Ctrl+]
            0x32 => "\x00",       // Ctrl+2 → NUL
            0x36 => "\x1e",       // Ctrl+6 → RS
            0xBD => "\x1f",       // Ctrl+- → US
            _ => null,
        };
    }
}
