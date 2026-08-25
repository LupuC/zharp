using System.Text.Json;
using System.Text.Json.Nodes;

namespace Zharp.App;

/// <summary>
/// Connects Claude Code to Zharp by installing lifecycle hooks into the user's
/// own Claude Code settings.
///
/// The hooks run <c>zharp-agent.ps1</c>, which answers with a terminal escape
/// sequence that Claude Code writes to the pty for us. Zharp reads it back out
/// the other end and knows exactly what the agent is doing, instead of reading
/// the screen and guessing.
///
/// Everything here is written to the user's file, so the rules are strict:
/// nothing that is not ours is touched, and disconnecting leaves the file as it
/// was found. That is why the hooks are identified by the script they run
/// rather than by position or by a marker field Claude Code might reject.
/// </summary>
public static class ClaudeCodeIntegration
{
    /// <summary>Which Claude Code event feeds which Zharp report.</summary>
    private static readonly (string Event, string Kind, string? Matcher)[] Hooks =
    [
        ("SessionStart", "start", "startup|resume|clear"),
        ("UserPromptSubmit", "prompt", null),

        // Only the tools that write. PostToolUse fires after every single tool
        // call, and each one costs a PowerShell start (~260ms measured), so
        // reporting reads and greps too would tax a turn for status nobody
        // reads. A file being written is also the only tool result the changes
        // panel can act on.
        ("PostToolUse", "tool", "Edit|Write|NotebookEdit"),

        // Once per batch of tool calls, not once per call, which is what makes
        // it affordable to subscribe to unconditionally. Its job is to say the
        // agent is moving again: no agent emits "that permission was answered",
        // and PostToolUse above only fires for writes, so a tab that asked to
        // run a command went on claiming to be blocked through every read and
        // search that followed.
        ("PostToolBatch", "working", null),

        ("PermissionRequest", "permission", null),
        ("Notification", "idle", "idle_prompt"),
        ("Stop", "done", null),
        ("StopFailure", "error", null),
        ("SessionEnd", "end", null),
    ];

    private const string ScriptName = "zharp-agent.ps1";

    /// <summary>
    /// Installs the hooks if they are missing or stale, unless the user has
    /// turned the integration off.
    ///
    /// This runs at startup without asking, which is a decision worth stating:
    /// an integration you have to go and find is one nobody switches on, and
    /// the whole value here is that Zharp knows what your agent is doing
    /// without you having set anything up. What makes it defensible is that it
    /// is narrow and reversible - it adds hooks that do nothing outside Zharp,
    /// touches no other part of the file, keeps a backup, and turning it off in
    /// Settings takes them straight back out and keeps them out.
    /// </summary>
    public static void Sync(bool enabled)
    {
        try
        {
            if (!IsClaudeCodePresent)
                return; // do not create a Claude config for someone without Claude

            if (!enabled)
            {
                // Switched off has to mean gone, not merely "not added again".
                // Leaving a previous install in place would keep the hooks
                // running for somebody who has said they do not want them.
                if (!IsConnected())
                    return;
                Disconnect();
                App.Log($"claude code: hooks removed from {SettingsPath}");
                return;
            }

            if (IsCurrent())
                return;

            Connect();
            App.Log($"claude code: hooks installed at {SettingsPath}");
        }
        catch (Exception ex)
        {
            // Never worth failing a launch over.
            App.Log($"claude code: could not install hooks: {ex.Message}");
        }
    }

    /// <summary>The hook script, shipped next to the executable.</summary>
    public static string ScriptPath { get; } = Path.Combine(
        AppContext.BaseDirectory, "Integrations", "ClaudeCode", ScriptName);

    /// <summary>
    /// The user's Claude Code settings file, whether or not it exists.
    ///
    /// ZHARP_CLAUDE_SETTINGS redirects it, which is how the merge and unmerge
    /// get exercised against a copy rather than against the file somebody
    /// actually works in. Same idea as ZHARP_DUMP_PTY.
    /// </summary>
    public static string SettingsPath { get; } =
        Environment.GetEnvironmentVariable("ZHARP_CLAUDE_SETTINGS") is { Length: > 0 } custom
            ? custom
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".claude", "settings.json");

    /// <summary>Whether Claude Code is installed at all, so the UI can say so.</summary>
    public static bool IsClaudeCodePresent =>
        Directory.Exists(Path.GetDirectoryName(SettingsPath)!)
        || ShellDiscovery.FindOnPath("claude.exe") != null
        || ShellDiscovery.FindOnPath("claude.cmd") != null;

    /// <summary>True when our hooks are in the settings file right now.</summary>
    public static bool IsConnected()
    {
        try
        {
            if (Read() is not { } root || root["hooks"] is not JsonObject hooks)
                return false;
            foreach (var (name, _, _) in Hooks)
            {
                if (hooks[name] is JsonArray groups && groups.Any(IsOurs))
                    return true;
            }
            return false;
        }
        catch (Exception ex)
        {
            App.Log($"claude code: could not read settings: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Connected on every event, by this build, at this path.
    ///
    /// Stricter than <see cref="IsConnected"/> on purpose: it is the question
    /// "is there anything to do", and the answer is yes after an update moves
    /// the executable, after a partial write, and after a new event is added to
    /// the list above. All three leave hooks that look installed and are stale.
    /// </summary>
    public static bool IsCurrent()
    {
        try
        {
            if (Read() is not { } root || root["hooks"] is not JsonObject hooks)
                return false;

            // Compared against what Connect would write, in full, rather than
            // against the parts that seemed to matter. Anything we change
            // later - a timeout, a matcher, a new event - then repairs itself
            // on the next launch instead of needing to be remembered here.
            foreach (var (name, kind, matcher) in Hooks)
            {
                var want = Group(kind, matcher);
                if (hooks[name] is not JsonArray groups
                    || !groups.Any(g => JsonNode.DeepEquals(g, want)))
                    return false;
            }
            return true;
        }
        catch (Exception ex)
        {
            App.Log($"claude code: could not read settings: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Adds the hooks, replacing any earlier set of ours (so reconnecting after
    /// an upgrade repoints them at the new install rather than doubling up).
    /// </summary>
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

        Write(root);
    }

    /// <summary>
    /// Takes the hooks back out, and any container they leave empty with them.
    /// A user who disconnects should not be able to tell we were ever here.
    /// </summary>
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
            root.Remove("hooks");

        Write(root);
    }

    private static JsonObject Group(string kind, string? matcher)
    {
        // The exec form: an executable plus argument array, passed through with
        // no shell in between. The shell form would leave the script path at
        // the mercy of quoting rules that differ between the shells Claude Code
        // might pick on Windows, and "Program Files" would find every one.
        var hook = new JsonObject
        {
            ["type"] = "command",
            ["command"] = "powershell.exe",
            ["args"] = new JsonArray(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", ScriptPath,
                kind),

            // A status update is never worth stalling a turn for. The default
            // is measured in minutes.
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
    /// Ours if it runs our script. Identity comes from the command line rather
    /// than a marker property because Claude Code validates hook objects and an
    /// unknown field is a rejected config, not a harmless note to ourselves.
    /// Matching on the file name rather than the full path means a Zharp that
    /// has moved still recognizes, and cleans up, its own old hooks.
    /// </summary>
    private static bool IsOurs(JsonNode? group)
    {
        if (group is not JsonObject obj || obj["hooks"] is not JsonArray hooks)
            return false;

        foreach (var hook in hooks)
        {
            if (hook is not JsonObject h || h["args"] is not JsonArray args)
                continue;
            foreach (var arg in args)
            {
                if (arg?.GetValue<string>() is { } text
                    && text.EndsWith(ScriptName, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }
        return false;
    }

    private static JsonObject? Read()
    {
        if (!File.Exists(SettingsPath))
            return null;
        string text = File.ReadAllText(SettingsPath);
        if (string.IsNullOrWhiteSpace(text))
            return null;
        return JsonNode.Parse(text, documentOptions: new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        }) as JsonObject;
    }

    /// <summary>
    /// Replaces the settings file in one step, keeping a copy of what was there
    /// the first time we ever touch it. This is a file the user edits by hand
    /// and depends on daily; it should survive us being wrong.
    /// </summary>
    private static void Write(JsonObject root)
    {
        string directory = Path.GetDirectoryName(SettingsPath)!;
        Directory.CreateDirectory(directory);

        string backup = SettingsPath + ".zharp-backup";
        if (File.Exists(SettingsPath) && !File.Exists(backup))
            File.Copy(SettingsPath, backup);

        string json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        string temp = SettingsPath + ".zharp-tmp";
        File.WriteAllText(temp, json);

        // Move over the top rather than writing in place: a crash halfway
        // through leaves the old settings intact instead of half a file.
        File.Move(temp, SettingsPath, overwrite: true);
    }
}
