using System.Text.Json;
using System.Text.Json.Nodes;

namespace Zharp.App;

/// <summary>
/// Connects Codex to Zharp by installing lifecycle hooks into the user's own
/// Codex config.
///
/// The same idea as <see cref="ClaudeCodeIntegration"/> and the same care with
/// somebody else's file, but the plumbing underneath is not the same. Codex has
/// no way for a hook to return a terminal escape sequence, so its hooks report
/// through <see cref="AgentSpool"/> instead. The hook script is node rather
/// than PowerShell, because Codex ships as an npm package and so node is always
/// present where Codex is, and it starts in about a third of the time.
///
/// Two things are different for the user, and neither is ours to hide:
///
/// Codex will not run a hook it has not been told to trust. Zharp writes the
/// config; the review prompt inside Codex is the user's to answer, and trying
/// to route around it would be defeating a safety feature that exists for
/// exactly the situation of a program writing hooks into your agent.
///
/// And <c>notify</c> is not usable. It holds one program, and OpenAI's own
/// tooling already claims it on plenty of machines; taking it would break
/// whatever was there.
/// </summary>
public static class CodexIntegration
{
    /// <summary>Which Codex event feeds which Zharp report.</summary>
    private static readonly (string Event, string Kind, string? Matcher)[] Hooks =
    [
        ("SessionStart", "start", null),
        ("UserPromptSubmit", "prompt", null),

        // Every tool, not just the ones that write. Codex has no once-per-batch
        // event, so this is also the only signal that the agent is running
        // again after a permission prompt was answered; without it a tab would
        // go on claiming to be blocked for the rest of the turn. Affordable
        // because the hook is node: ~48ms a call against PowerShell's ~139ms.
        ("PostToolUse", "tool", null),

        ("PermissionRequest", "permission", null),
        ("Stop", "done", null),
        ("SessionEnd", "end", null),
    ];

    private const string ScriptName = "zharp-agent.js";

    /// <summary>The hook script, shipped next to the executable.</summary>
    public static string ScriptPath { get; } = Path.Combine(
        AppContext.BaseDirectory, "Integrations", "Codex", ScriptName);

    /// <summary>
    /// Codex reads hooks from config.toml as well, but this is the JSON one and
    /// it takes precedence. Writing TOML would mean parsing and rewriting a
    /// file full of the user's project trust settings; this file is usually
    /// ours alone, and JSON round trips without losing a comment.
    /// </summary>
    public static string HooksPath { get; } =
        Environment.GetEnvironmentVariable("ZHARP_CODEX_HOOKS") is { Length: > 0 } custom
            ? custom
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex", "hooks.json");

    /// <summary>Whether Codex is on this machine at all.</summary>
    public static bool IsCodexPresent =>
        Directory.Exists(Path.GetDirectoryName(HooksPath)!)
        || ShellDiscovery.FindOnPath("codex.cmd") != null
        || ShellDiscovery.FindOnPath("codex.exe") != null;

    /// <summary>Node has to exist to run the hook, and it ships with Codex.</summary>
    public static bool IsNodeAvailable => ShellDiscovery.FindOnPath("node.exe") != null;

    /// <summary>True when our hooks are in the file right now.</summary>
    public static bool IsConnected()
    {
        try
        {
            if (Read() is not { } root || root["hooks"] is not JsonObject hooks)
                return false;
            return Hooks.Any(h => hooks[h.Event] is JsonArray groups && groups.Any(IsOurs));
        }
        catch (Exception ex)
        {
            App.Log($"codex: could not read hooks: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Connected on every event, by this build, at this path. The question is
    /// "is there anything to do": an update moves the executable and leaves
    /// hooks pointing at a script that is not there any more.
    /// </summary>
    public static bool IsCurrent()
    {
        try
        {
            if (Read() is not { } root || root["hooks"] is not JsonObject hooks)
                return false;

            foreach (var (name, kind, _) in Hooks)
            {
                if (hooks[name] is not JsonArray groups || !groups.Any(g => RunsExactly(g, kind)))
                    return false;
            }
            return true;
        }
        catch (Exception ex)
        {
            App.Log($"codex: could not read hooks: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Installs the hooks if they are missing or stale, removes them when the
    /// integration is switched off, and does nothing at all without Codex.
    /// </summary>
    /// <returns>True when the file was changed, so the caller can mention the
    /// review Codex is about to ask for.</returns>
    public static bool Sync(bool enabled)
    {
        try
        {
            if (!IsCodexPresent || !IsNodeAvailable)
                return false;

            if (!enabled)
            {
                if (!IsConnected())
                    return false;
                Disconnect();
                App.Log($"codex: hooks removed from {HooksPath}");
                return false;
            }

            if (IsCurrent())
                return false;

            Connect();
            App.Log($"codex: hooks installed at {HooksPath}");
            return true;
        }
        catch (Exception ex)
        {
            App.Log($"codex: could not install hooks: {ex.Message}");
            return false;
        }
    }

    public static void Connect()
    {
        var root = Read() ?? new JsonObject();

        if (root["hooks"] is not JsonObject hooks)
        {
            hooks = new JsonObject();
            root["hooks"] = hooks;
        }

        foreach (var (name, kind, matcher) in Hooks)
        {
            if (hooks[name] is not JsonArray groups)
            {
                groups = new JsonArray();
                hooks[name] = groups;
            }

            DropOurs(groups);
            groups.Add(Group(kind, matcher));
        }

        // Codex shows this above the review prompt, so it is the one chance to
        // say who wrote these and why before the user decides.
        root["description"] ??= "Zharp terminal: reports agent status to the tab it is running in.";

        Write(root);
    }

    public static void Disconnect()
    {
        if (Read() is not { } root || root["hooks"] is not JsonObject hooks)
            return;

        foreach (var (name, _, _) in Hooks)
        {
            if (hooks[name] is not JsonArray groups)
                continue;
            DropOurs(groups);
            if (groups.Count == 0)
                hooks.Remove(name);
        }

        if (hooks.Count == 0)
        {
            root.Remove("hooks");
            root.Remove("description");
        }

        // A file that now says nothing is one we created. Leaving an empty
        // shell behind would be litter in somebody else's directory.
        if (root.Count == 0)
        {
            try { File.Delete(HooksPath); } catch { }
            return;
        }

        Write(root);
    }

    private static JsonObject Group(string kind, string? matcher)
    {
        // commandWindows is Codex's own Windows override, and it is a command
        // line rather than an argument list, so the script path is quoted: the
        // default install lives under Program Files.
        string command = $"node \"{ScriptPath}\" {kind}";

        var hook = new JsonObject
        {
            ["type"] = "command",
            ["command"] = command,
            ["commandWindows"] = command,

            // Status is never worth stalling a turn for. Codex defaults to 600.
            ["timeout"] = 5,
        };

        var group = new JsonObject();
        if (matcher != null)
            group["matcher"] = matcher;
        group["hooks"] = new JsonArray(hook);
        return group;
    }

    private static void DropOurs(JsonArray groups)
    {
        for (int i = groups.Count - 1; i >= 0; i--)
        {
            if (IsOurs(groups[i]))
                groups.RemoveAt(i);
        }
    }

    /// <summary>
    /// Ours if it runs our script. Matched on the file name rather than the
    /// full path so a Zharp that has moved still recognizes, and cleans up,
    /// its own old hooks.
    /// </summary>
    private static bool IsOurs(JsonNode? group) => Commands(group)
        .Any(c => c.Contains(ScriptName, StringComparison.OrdinalIgnoreCase));

    /// <summary>This exact script, at this exact path, for this exact event.</summary>
    private static bool RunsExactly(JsonNode? group, string kind) => Commands(group)
        .Any(c => c.Contains(ScriptPath, StringComparison.OrdinalIgnoreCase)
                  && c.EndsWith(" " + kind, StringComparison.Ordinal));

    private static IEnumerable<string> Commands(JsonNode? group)
    {
        if (group is not JsonObject obj || obj["hooks"] is not JsonArray hooks)
            yield break;

        foreach (var hook in hooks)
        {
            if (hook is not JsonObject h)
                continue;
            foreach (string key in new[] { "command", "commandWindows" })
            {
                if (h[key]?.GetValue<string>() is { Length: > 0 } text)
                    yield return text;
            }
        }
    }

    private static JsonObject? Read()
    {
        if (!File.Exists(HooksPath))
            return null;
        string text = File.ReadAllText(HooksPath);
        if (string.IsNullOrWhiteSpace(text))
            return null;
        return JsonNode.Parse(text, documentOptions: new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        }) as JsonObject;
    }

    private static void Write(JsonObject root)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(HooksPath)!);

        string backup = HooksPath + ".zharp-backup";
        if (File.Exists(HooksPath) && !File.Exists(backup))
            File.Copy(HooksPath, backup);

        string json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        string temp = HooksPath + ".zharp-tmp";
        File.WriteAllText(temp, json);
        File.Move(temp, HooksPath, overwrite: true);
    }
}
