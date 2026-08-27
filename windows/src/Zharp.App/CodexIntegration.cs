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
    /// <summary>
    /// How long a hook may take. Never worth stalling a turn for status, and
    /// the script is a node start and a small write, so this is already
    /// generous. Codex would otherwise default to 600 seconds.
    /// </summary>
    private const int Timeout = 3;

    /// <summary>
    /// Which Codex event feeds which Zharp report.
    ///
    /// Every timeout is <see cref="Timeout"/> rather than something larger,
    /// because Codex caps SessionEnd hooks at three seconds and prints a
    /// warning into the session when it has to clamp one. Asking for more than
    /// we need bought nothing and put a complaint on the user's screen.
    /// </summary>
    private static readonly (string Event, string Kind, string? Matcher)[] Hooks =
    [
        ("PermissionRequest", "permission", null),
    ];

    // One hook, and only because there is no other way to know.
    //
    // Every hook invocation on Windows is two processes, cmd.exe and then node,
    // because Codex has no argv form: there is only a command line, and it goes
    // through a shell. You can watch them appear. Three hooks a turn was still
    // two processes on every prompt, for status Zharp can work out on its own.
    //
    // What it cannot work out on its own is that the agent is blocked waiting
    // for you, and that is the one thing worth a process. It fires only when
    // Codex actually stops to ask, which is rare and is already a moment you
    // are being interrupted.
    //
    // Everything else comes free:
    //
    //   running, and for how long - read off the screen, as it was before any
    //   of this, which costs nothing because the output is already being parsed
    //
    //   the agent started - Zharp read the command that started it
    //
    //   the agent exited - the shell drawing its prompt again says so
    //
    //   the permission was answered - you typed, and Zharp is holding the
    //   keyboard
    //
    // Claude Code is subscribed to far more, because its hooks take an argument
    // list rather than a command line and so spawn no shell at all. The cost is
    // the platform's, not the idea's.
    //
    // Codex has no argv form for a hook: there is only a command line, and on
    // Windows it goes through cmd.exe. So every hook invocation is two
    // processes, cmd.exe and then node. Subscribing to PostToolUse, which is
    // what an earlier version did to catch every file a tool wrote, meant two
    // processes for every tool call an agent made. You could watch them
    // appear, and the terminal was slower for it.
    //
    // What was dropped, and why it costs nothing:
    //
    //   SessionStart - Zharp already knows Codex is running, because it read
    //   the command that started it.
    //
    //   SessionEnd - the shell drawing its prompt again says the agent has
    //   exited, and says it more reliably than a hook running inside a process
    //   that is busy dying.
    //
    //   PostToolUse - the expensive one. It bought a live "editing that file"
    //   line and let the changes panel follow along, and neither is worth a
    //   pair of processes per tool call. Claude Code keeps both because it
    //   takes an argument list rather than a command line, so there is no
    //   shell, and because its hook can be matched to just the tools that
    //   write. Codex can do neither.
    //
    // A permission that has been answered is noticed without any hook at all:
    // typing into a session is Zharp's own signal that the user has replied.

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

            // And nothing of ours anywhere else. Checking only that today's
            // hooks are present would call a file current while an older
            // version's PostToolUse entry sat in it still firing on every tool
            // call, because everything this version looks for was indeed there.
            foreach (var pair in hooks)
            {
                if (Hooks.Any(h => h.Event == pair.Key))
                    continue;
                if (pair.Value is JsonArray extra && extra.Any(IsOurs))
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

        // Sweep every event first, not only the ones installed today. A
        // previous version of Zharp subscribed to more of them, and an entry
        // left on an event this version no longer knows about would go on
        // running a script we have stopped meaning to run - which for
        // PostToolUse meant a pair of processes on every tool call, forever.
        SweepOurs(hooks);

        foreach (var (name, kind, matcher) in Hooks)
        {
            if (hooks[name] is not JsonArray groups)
            {
                groups = new JsonArray();
                hooks[name] = groups;
            }
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

        SweepOurs(hooks);

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
            ["timeout"] = Timeout,
        };

        var group = new JsonObject();
        if (matcher != null)
            group["matcher"] = matcher;
        group["hooks"] = new JsonArray(hook);
        return group;
    }

    /// <summary>
    /// Takes our hooks out of every event in the file, and removes any event
    /// left with nothing in it. Keyed on the script rather than on the list of
    /// events above, so a hook this version does not know it ever installed is
    /// still cleaned up.
    /// </summary>
    private static void SweepOurs(JsonObject hooks)
    {
        foreach (string name in hooks.Select(pair => pair.Key).ToList())
        {
            if (hooks[name] is not JsonArray groups)
                continue;
            DropOurs(groups);
            if (groups.Count == 0)
                hooks.Remove(name);
        }
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
