import Foundation

/// Connects Claude Code to Zharp by installing lifecycle hooks into the user's
/// own Claude Code settings.
///
/// The hooks run `zharp-agent-claude.sh`, which answers with a terminal escape
/// sequence that Claude Code writes to the pty for us. Zharp reads it back out
/// the other end and knows exactly what the agent is doing, instead of reading
/// the screen and guessing.
///
/// Everything here is written to the user's file, so the rules are strict:
/// nothing that is not ours is touched, and disconnecting leaves the file as it
/// was found. That is why the hooks are identified by the script they run
/// rather than by position or by a marker field Claude Code might reject.
enum ClaudeCodeIntegration {

    /// Which Claude Code event feeds which Zharp report.
    private static let hooks: [(event: String, kind: String, matcher: String?)] = [
        ("SessionStart", "start", "startup|resume|clear"),
        ("UserPromptSubmit", "prompt", nil),

        // Only the tools that write. PostToolUse fires after every single tool
        // call, and reporting reads and greps too would tax a turn for status
        // nobody reads. A file being written is also the only tool result the
        // changes panel can act on.
        ("PostToolUse", "tool", "Edit|Write|NotebookEdit"),

        // Once per batch of tool calls, not once per call, which is what makes
        // it affordable to subscribe to unconditionally. Its job is to say the
        // agent is moving again: no agent emits "that permission was answered",
        // and PostToolUse above only fires for writes, so a tab that asked to
        // run a command went on claiming to be blocked through every read and
        // search that followed.
        ("PostToolBatch", "working", nil),

        ("PermissionRequest", "permission", nil),
        ("Notification", "idle", "idle_prompt"),
        ("Stop", "done", nil),
        ("StopFailure", "error", nil),
        ("SessionEnd", "end", nil),
    ]

    /// The name the hook script ships under, minus its extension.
    private static let scriptName = "zharp-agent-claude"

    /// What makes a hook ours, wherever it is and whatever it is called.
    ///
    /// Deliberately looser than the current file name. It matches the `.ps1`
    /// the Windows build installs and any name a past or future macOS build
    /// used, so a hook Zharp has stopped meaning to run is always one it can
    /// still find and take out.
    private static let marker = "zharp-agent"

    /// The hook script, out of the app bundle. Optional because a build that
    /// failed to stage it should install nothing at all: a hook pointing at a
    /// file that is not there is worse than no hook, since it looks installed.
    static var scriptPath: String? {
        Resources.url(forResource: scriptName, withExtension: "sh")?.path
    }

    /// The user's Claude Code settings file, whether or not it exists.
    ///
    /// ZHARP_CLAUDE_SETTINGS redirects it, which is how the merge and unmerge
    /// get exercised against a copy rather than against the file somebody
    /// actually works in. CLAUDE_CONFIG_DIR is Claude Code's own relocation
    /// switch, which the Windows build does not honour and should.
    static let settingsURL: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["ZHARP_CLAUDE_SETTINGS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let configDirectory = environment["CLAUDE_CONFIG_DIR"], !configDirectory.isEmpty {
            return URL(fileURLWithPath: configDirectory).appendingPathComponent("settings.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }()

    /// Whether Claude Code is installed at all, so the UI can say so.
    ///
    /// The config directory is what carries this in practice. A GUI app
    /// inherits a minimal PATH, and none of the three ways Claude Code installs
    /// itself put their binary anywhere on it, so the two explicit paths below
    /// are worth more here than a PATH search is.
    static var isClaudeCodePresent: Bool {
        let files = FileManager.default
        if files.fileExists(atPath: settingsURL.deletingLastPathComponent().path) { return true }
        if ShellDiscovery.findOnPath("claude") != nil { return true }
        let home = NSHomeDirectory()
        return files.isExecutableFile(atPath: home + "/.local/bin/claude")
            || files.isExecutableFile(atPath: home + "/.claude/local/claude")
    }

    /// Installs the hooks if they are missing or stale, unless the user has
    /// turned the integration off.
    ///
    /// This runs at startup without asking, which is a decision worth stating:
    /// an integration you have to go and find is one nobody switches on, and
    /// the whole value here is that Zharp knows what your agent is doing
    /// without you having set anything up. What makes it defensible is that it
    /// is narrow and reversible. It adds hooks that do nothing outside Zharp,
    /// touches no other part of the file, keeps a backup, and turning it off in
    /// Settings takes them straight back out and keeps them out.
    static func sync(enabled: Bool) {
        do {
            // Do not create a Claude config for somebody without Claude.
            guard isClaudeCodePresent else { return }

            if !enabled {
                // Switched off has to mean gone, not merely "not added again".
                // Leaving a previous install in place would keep the hooks
                // running for somebody who has said they do not want them.
                guard isConnected() else { return }
                try disconnect()
                App.log("claude code: hooks removed from \(settingsURL.path)")
                return
            }

            guard scriptPath != nil else {
                App.log("claude code: \(scriptName).sh is missing from the bundle")
                return
            }
            if isCurrent() { return }

            try connect()
            App.log("claude code: hooks installed at \(settingsURL.path)")
        } catch {
            // Never worth failing a launch over, and a settings file that did
            // not parse is one that has just been left alone on purpose.
            App.log("claude code: could not install hooks: \(error)")
        }
    }

    /// True when a hook of ours is in the settings file right now, on any event
    /// at all.
    ///
    /// Every event rather than only the ones subscribed to today. This is the
    /// question `sync` asks before removing anything, and a hook left behind on
    /// an event a past version knew about is exactly the one that most needs
    /// removing: it is still firing, and nothing in this build is going to
    /// rewrite it.
    static func isConnected() -> Bool {
        do {
            guard let root = try AgentConfigFile.read(settingsURL),
                  let installed = root["hooks"] as? [String: Any] else { return false }
            return installed.values.contains { value in
                guard let groups = value as? [Any] else { return false }
                return groups.contains(where: isOurs)
            }
        } catch {
            App.log("claude code: could not read settings: \(error)")
            return false
        }
    }

    /// Connected on every event, by this build, at this path.
    ///
    /// Stricter than `isConnected()` on purpose: it is the question "is there
    /// anything to do", and the answer is yes after an update moves the app,
    /// after a partial write, and after a new event is added to the list above.
    /// All three leave hooks that look installed and are stale.
    static func isCurrent() -> Bool {
        do {
            guard let script = scriptPath,
                  let root = try AgentConfigFile.read(settingsURL),
                  let installed = root["hooks"] as? [String: Any] else { return false }

            // Compared against what connect() would write, in full, rather than
            // against the parts that seemed to matter. Anything changed later
            // (a timeout, a matcher, a new event) then repairs itself on the
            // next launch instead of needing to be remembered here.
            for entry in hooks {
                let wanted = group(kind: entry.kind, matcher: entry.matcher, script: script)
                guard let groups = installed[entry.event] as? [Any],
                      groups.contains(where: { AgentConfigFile.matches($0, wanted) })
                else { return false }
            }

            // And nothing of ours anywhere else, so an event a previous version
            // subscribed to does not stay behind running.
            for (event, value) in installed where !hooks.contains(where: { $0.event == event }) {
                if let extra = value as? [Any], extra.contains(where: isOurs) { return false }
            }
            return true
        } catch {
            App.log("claude code: could not read settings: \(error)")
            return false
        }
    }

    /// Adds the hooks, replacing any earlier set of ours (so reconnecting after
    /// an upgrade repoints them at the new install rather than doubling up).
    static func connect() throws {
        guard let script = scriptPath else { return }

        var root = try AgentConfigFile.read(settingsURL) ?? [:]
        var installed = root["hooks"] as? [String: Any] ?? [:]

        // Every event, not only the ones installed today: a previous version
        // may have subscribed to more, and an entry left behind on an event
        // this version no longer knows about would keep running.
        sweepOurs(&installed)

        for entry in hooks {
            var groups = installed[entry.event] as? [Any] ?? []
            groups.append(group(kind: entry.kind, matcher: entry.matcher, script: script))
            installed[entry.event] = groups
        }

        root["hooks"] = installed
        try AgentConfigFile.write(root, to: settingsURL)
    }

    /// Takes the hooks back out, and any container they leave empty with them.
    /// A user who disconnects should not be able to tell we were ever here.
    static func disconnect() throws {
        guard var root = try AgentConfigFile.read(settingsURL),
              var installed = root["hooks"] as? [String: Any] else { return }

        sweepOurs(&installed)

        if installed.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = installed
        }
        try AgentConfigFile.write(root, to: settingsURL)
    }

    private static func group(kind: String, matcher: String?, script: String) -> [String: Any] {
        // The exec form: an executable plus an argument array, with no shell in
        // between. Naming /bin/sh rather than relying on a shebang also means
        // the hook does not depend on the executable bit surviving SwiftPM's
        // resource staging and the .app assembly, and an app bundle path with a
        // space in it never meets a quoting rule.
        let hook: [String: Any] = [
            "type": "command",
            "command": "/bin/sh",
            "args": [script, kind],

            // A status update is never worth stalling a turn for. The default
            // is measured in minutes.
            "timeout": 5,
        ]

        var group: [String: Any] = [:]
        if let matcher { group["matcher"] = matcher }
        group["hooks"] = [hook]
        return group
    }

    /// Takes our hooks out of every event in the file, and removes any event
    /// left with nothing in it. Keyed on the script rather than on the list of
    /// events above, so a hook this version does not know it ever installed is
    /// still cleaned up.
    private static func sweepOurs(_ installed: inout [String: Any]) {
        for (event, value) in installed {
            guard var groups = value as? [Any] else { continue }
            groups.removeAll(where: isOurs)
            if groups.isEmpty {
                installed.removeValue(forKey: event)
            } else {
                installed[event] = groups
            }
        }
    }

    /// Ours if it runs our script. Identity comes from the command line rather
    /// than a marker property because Claude Code validates hook objects and an
    /// unknown field is a rejected config, not a harmless note to ourselves.
    /// Matching on part of the file name rather than the full path means a
    /// Zharp that has moved still recognizes, and cleans up, its own old hooks.
    private static func isOurs(_ group: Any) -> Bool {
        guard let object = group as? [String: Any],
              let entries = object["hooks"] as? [Any] else { return false }

        for entry in entries {
            guard let hook = entry as? [String: Any] else { continue }
            if let command = hook["command"] as? String, command.contains(marker) { return true }
            guard let args = hook["args"] as? [Any] else { continue }
            for argument in args {
                if let text = argument as? String, text.contains(marker) { return true }
            }
        }
        return false
    }
}
