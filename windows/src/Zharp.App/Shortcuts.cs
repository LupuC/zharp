using Windows.System;

namespace Zharp.App;

/// <summary>A rebindable application action.</summary>
public sealed record ShortcutAction(string Id, string DisplayName, string DefaultBinding);

/// <summary>
/// The app's rebindable shortcuts: defaults, parsing "Ctrl+Shift+T"-style
/// binding strings, and formatting captured key combinations back into them.
/// </summary>
public static class Shortcuts
{
    public static readonly ShortcutAction[] Actions =
    [
        new("newTab", "New session", "Ctrl+Shift+T"),
        new("closeTab", "Close session", "Ctrl+Shift+W"),
        new("nextTab", "Next session", "Ctrl+Tab"),
        new("prevTab", "Previous session", "Ctrl+Shift+Tab"),
        new("toggleSidebar", "Toggle tab panel", "Ctrl+Shift+B"),
        new("openSettings", "Open settings", "Ctrl+,"),
        new("openDiff", "Open changes", "Ctrl+Shift+D"),
        new("toggleSearch", "Toggle search", "Ctrl+Shift+F"),
        new("zoomIn", "Zoom in", "Ctrl+="),
        new("zoomOut", "Zoom out", "Ctrl+-"),
        new("zoomReset", "Reset zoom", "Ctrl+0"),
        new("blockPrev", "Previous block", "Ctrl+Up"),
        new("blockNext", "Next block", "Ctrl+Down"),
        new("copyOutput", "Copy block output", "Ctrl+Shift+O"),
        new("findInBlock", "Find within block", "Ctrl+Shift+G"),
    ];

    /// <summary>Actions handled inside the focused terminal (block actions):
    /// they are rebindable but not registered as window accelerators, so they
    /// can fall through to the shell when no blocks exist.</summary>
    public static bool IsTerminalScope(string actionId) =>
        actionId is "blockPrev" or "blockNext" or "copyOutput" or "findInBlock";

    /// <summary>The user's binding for an action, falling back to the default.</summary>
    public static string GetBinding(AppSettings settings, string actionId)
    {
        if (settings.Keybindings.TryGetValue(actionId, out string? binding) &&
            !string.IsNullOrWhiteSpace(binding))
        {
            return binding;
        }
        return Actions.First(a => a.Id == actionId).DefaultBinding;
    }

    // Punctuation keys that VirtualKey has no friendly names for.
    private static readonly (string Name, int Vk)[] SpecialKeys =
    [
        ("=", 187), ("-", 189), (",", 188), (".", 190), (";", 186),
        ("'", 222), ("[", 219), ("]", 221), ("\\", 220), ("`", 192), ("/", 191),
    ];

    public static bool TryParse(string binding, out VirtualKeyModifiers modifiers, out int virtualKey)
    {
        modifiers = VirtualKeyModifiers.None;
        virtualKey = 0;
        if (string.IsNullOrWhiteSpace(binding))
            return false;

        string[] parts = binding.Split('+', StringSplitOptions.TrimEntries);
        // A trailing "+" key (e.g. "Ctrl++") would confuse Split; bindings use "=" instead.
        for (int i = 0; i < parts.Length; i++)
        {
            string part = parts[i];
            bool isLast = i == parts.Length - 1;
            switch (part.ToLowerInvariant())
            {
                case "ctrl" or "control" when !isLast: modifiers |= VirtualKeyModifiers.Control; continue;
                case "shift" when !isLast: modifiers |= VirtualKeyModifiers.Shift; continue;
                case "alt" when !isLast: modifiers |= VirtualKeyModifiers.Menu; continue;
                case "win" when !isLast: modifiers |= VirtualKeyModifiers.Windows; continue;
            }
            if (!isLast)
                return false;
            virtualKey = ParseKey(part);
        }
        return virtualKey != 0;
    }

    private static int ParseKey(string token)
    {
        if (token.Length == 1)
        {
            char c = char.ToUpperInvariant(token[0]);
            if (c is >= 'A' and <= 'Z' or >= '0' and <= '9')
                return c;
            foreach (var (name, vk) in SpecialKeys)
                if (name[0] == token[0])
                    return vk;
            return 0;
        }
        if (token.Length is 2 or 3 && (token[0] is 'F' or 'f') &&
            int.TryParse(token[1..], out int f) && f is >= 1 and <= 24)
        {
            return 0x70 + f - 1;
        }
        return Enum.TryParse<VirtualKey>(token, ignoreCase: true, out var key) ? (int)key : 0;
    }

    /// <summary>Formats a captured combination, or null if the key is unsupported.</summary>
    public static string? Format(VirtualKeyModifiers modifiers, int virtualKey)
    {
        string? key = FormatKey(virtualKey);
        if (key == null)
            return null;
        var parts = new List<string>(4);
        if (modifiers.HasFlag(VirtualKeyModifiers.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(VirtualKeyModifiers.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(VirtualKeyModifiers.Menu)) parts.Add("Alt");
        if (modifiers.HasFlag(VirtualKeyModifiers.Windows)) parts.Add("Win");
        parts.Add(key);
        return string.Join("+", parts);
    }

    private static string? FormatKey(int vk)
    {
        if (vk is >= 'A' and <= 'Z' or >= '0' and <= '9')
            return ((char)vk).ToString();
        foreach (var (name, special) in SpecialKeys)
            if (special == vk)
                return name;
        if (vk is >= 0x70 and <= 0x87)
            return "F" + (vk - 0x70 + 1);
        return vk switch
        {
            0x09 => "Tab",
            0x20 => "Space",
            0x21 => "PageUp",
            0x22 => "PageDown",
            0x23 => "End",
            0x24 => "Home",
            0x25 => "Left",
            0x26 => "Up",
            0x27 => "Right",
            0x28 => "Down",
            0x2D => "Insert",
            0x2E => "Delete",
            _ => null,
        };
    }
}
