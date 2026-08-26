import Foundation

/// Connects Codex to Zharp by installing lifecycle hooks into the user's own
/// Codex config.
///
/// The same idea as `ClaudeCodeIntegration` and the same care with somebody
/// else's file, but the plumbing underneath is not the same. Codex has no way
/// for a hook to return a terminal escape sequence, so its hooks report through
/// the spool directory instead. The hook script is node rather than sh, because
/// Codex ships as an npm package and so node is always present where Codex is.
///
/// Two things are different for the user, and neither is ours to hide:
///
/// Codex will not run a hook it has not been told to trust. Zharp writes the
/// config; the review prompt inside Codex is the user's to answer, and trying
/// to route around it would be defeating a safety feature that exists for
/// exactly the situation of a program writing hooks into your agent.
///
/// And `notify` is not usable. It holds one program, and OpenAI's own tooling
/// already claims it on plenty of machines; taking it would break whatever was
/// there.
enum CodexIntegration {

    /// How long a hook may take. Never worth stalling a turn for status, and
    /// the script is a node start and a small write, so this is already
    /// generous. Codex would otherwise default to 600 seconds.
    private static let timeout = 3

    /// Which Codex event feeds which Zharp report.
    ///
    /// Every timeout is `timeout` rather than something larger, because Codex
    /// caps SessionEnd hooks at three seconds and prints a warning into the
    /// session when it has to clamp one. Asking for more than we need bought
    /// nothing and put a complaint on the user's screen.
    private static let hooks: [(event: String, kind: String, matcher: String?)] = [
        ("PermissionRequest", "permission", nil),
    ]

    // One hook, and only because there is no other way to know.
    //
    // Codex has no argv form for a hook: there is only a command line, and it
    // goes through a shell. So every invocation is two processes here as well
    // as on Windows, /bin/sh and then node. Subscribing to PostToolUse, which
    // is what an earlier version did to catch every file a tool wrote, meant
    // two processes for every tool call an agent made. You could watch them
    // appear, and the terminal was slower for it.
    //
    // What Zharp cannot work out on its own is that the agent is blocked
    // waiting for you, and that is the one thing worth a process. It fires only
    // when Codex actually stops to ask, which is rare and is already a moment
    // you are being interrupted.
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

    private static let scriptName = "zharp-agent-codex"

    /// What makes a hook ours, wherever it is and whatever it is called. Looser
    /// than the current file name so that an entry written by a past version,
    /// or by the Windows build into a home directory shared with it, is still
    /// recognized and taken out.
    private static let marker = "zharp-agent"

    /// The hook script, out of the app bundle.
    static var scriptPath: String? {
        Resources.url(forResource: scriptName, withExtension: "js")?.path
    }

    /// Codex reads hooks from config.toml as well, but this is the JSON one and
    /// it takes precedence. Writing TOML would mean parsing and rewriting a
    /// file full of the user's project trust settings; this file is usually
    /// ours alone, and JSON round trips without losing a comment.
    ///
    /// CODEX_HOME is Codex's own relocation switch, which the Windows build
    /// does not honour and should.
    static let hooksURL: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["ZHARP_CODEX_HOOKS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("hooks.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/hooks.json")
    }()

    /// Whether Codex is on this machine at all.
    static var isCodexPresent: Bool {
        FileManager.default.fileExists(atPath: hooksURL.deletingLastPathComponent().path)
            || ShellDiscovery.findOnPath("codex") != nil
    }

    // Node is deliberately not checked for, which the Windows build does.
    //
    // A GUI app inherits a minimal PATH, and on a Mac node usually lives under
    // a version manager (nvm, fnm, asdf, volta) that is set up by a login
    // shell. Looking for it here answers "no" for most of the people who have
    // it, and answering no would mean never installing the integration for
    // them. It would also make switching the integration off unable to remove
    // hooks already installed, because the check runs first.
    //
    // The check was not buying anything either way. Codex ships as an npm
    // package, so node is present wherever Codex is, and the PATH that resolves
    // `node` in the hook is Codex's own, not Zharp's.

    /// True when a hook of ours is in the file right now, on any event at all.
    ///
    /// Every event rather than only the ones subscribed to today, which is
    /// where the Windows build has this wrong and is worth fixing there. It is
    /// the question `sync` asks before removing anything, and this list has
    /// already shrunk from six events to one: asking only about PermissionRequest
    /// would answer "nothing installed" for a file still carrying an old
    /// version's PostToolUse hook, and switching the integration off would then
    /// leave the expensive one running forever.
    static func isConnected() -> Bool {
        do {
            guard let root = try AgentConfigFile.read(hooksURL),
                  let installed = root["hooks"] as? [String: Any] else { return false }
            return installed.values.contains { value in
                guard let groups = value as? [Any] else { return false }
                return groups.contains(where: isOurs)
            }
        } catch {
            App.log("codex: could not read hooks: \(error)")
            return false
        }
    }

    /// Connected on every event, by this build, at this path. The question is
    /// "is there anything to do": an update moves the app and leaves hooks
    /// pointing at a script that is not there any more.
    static func isCurrent() -> Bool {
        do {
            guard let script = scriptPath,
                  let root = try AgentConfigFile.read(hooksURL),
                  let installed = root["hooks"] as? [String: Any] else { return false }

            for entry in hooks {
                let wanted = group(kind: entry.kind, matcher: entry.matcher, script: script)
                guard let groups = installed[entry.event] as? [Any],
                      groups.contains(where: { AgentConfigFile.matches($0, wanted) })
                else { return false }
            }

            // And nothing of ours anywhere else. Checking only that today's
            // hooks are present would call a file current while an older
            // version's PostToolUse entry sat in it still firing on every tool
            // call, because everything this version looks for was indeed there.
            for (event, value) in installed where !hooks.contains(where: { $0.event == event }) {
                if let extra = value as? [Any], extra.contains(where: isOurs) { return false }
            }
            return true
        } catch {
            App.log("codex: could not read hooks: \(error)")
            return false
        }
    }

    /// Installs the hooks if they are missing or stale, removes them when the
    /// integration is switched off, and does nothing at all without Codex.
    ///
    /// Returns true when the file was changed, so the caller can mention the
    /// review Codex is about to ask for.
    @discardableResult
    static func sync(enabled: Bool) -> Bool {
        do {
            guard isCodexPresent else { return false }

            if !enabled {
                guard isConnected() else { return false }
                try disconnect()
                App.log("codex: hooks removed from \(hooksURL.path)")
                return false
            }

            guard scriptPath != nil else {
                App.log("codex: \(scriptName).js is missing from the bundle")
                return false
            }
            if isCurrent() { return false }

            try connect()
            App.log("codex: hooks installed at \(hooksURL.path)")
            return true
        } catch {
            App.log("codex: could not install hooks: \(error)")
            return false
        }
    }

    static func connect() throws {
        guard let script = scriptPath else { return }

        var root = try AgentConfigFile.read(hooksURL) ?? [:]
        var installed = root["hooks"] as? [String: Any] ?? [:]

        // Sweep every event first, not only the ones installed today. A
        // previous version of Zharp subscribed to more of them, and an entry
        // left on an event this version no longer knows about would go on
        // running a script we have stopped meaning to run, which for
        // PostToolUse meant a pair of processes on every tool call, forever.
        sweepOurs(&installed)

        for entry in hooks {
            var groups = installed[entry.event] as? [Any] ?? []
            groups.append(group(kind: entry.kind, matcher: entry.matcher, script: script))
            installed[entry.event] = groups
        }

        root["hooks"] = installed

        // Codex shows this above the review prompt, so it is the one chance to
        // say who wrote these and why before the user decides. Only when the
        // file does not already carry one of the user's own.
        if root["description"] == nil {
            root["description"] = "Zharp terminal: reports agent status to the tab it is running in."
        }

        try AgentConfigFile.write(root, to: hooksURL)
    }

    static func disconnect() throws {
        guard var root = try AgentConfigFile.read(hooksURL),
              var installed = root["hooks"] as? [String: Any] else { return }

        sweepOurs(&installed)

        if installed.isEmpty {
            root.removeValue(forKey: "hooks")
            root.removeValue(forKey: "description")
        } else {
            root["hooks"] = installed
        }

        // A file that now says nothing is one we created. Leaving an empty
        // shell behind would be litter in somebody else's directory.
        if root.isEmpty {
            try? FileManager.default.removeItem(at: hooksURL)
            return
        }

        try AgentConfigFile.write(root, to: hooksURL)
    }

    private static func group(kind: String, matcher: String?, script: String) -> [String: Any] {
        // A command line, not an argument list, because Codex has no argv form.
        // Single-quoted rather than double, since Codex hands this to a shell
        // and the app bundle path is not ours to make assumptions about.
        //
        // commandWindows, which the Windows build writes alongside this, is
        // deliberately absent: it means nothing here, and a Windows-shaped key
        // in a Mac user's hooks.json is litter. isOurs() still reads it, so a
        // hook written by the other build is recognized and swept.
        let command = "node \(AgentConfigFile.shellQuoted(script)) \(kind)"

        let hook: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout,
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

    /// Ours if it runs our script. Matched on part of the file name rather than
    /// the full path so a Zharp that has moved still recognizes, and cleans up,
    /// its own old hooks.
    private static func isOurs(_ group: Any) -> Bool {
        guard let object = group as? [String: Any],
              let entries = object["hooks"] as? [Any] else { return false }

        for entry in entries {
            guard let hook = entry as? [String: Any] else { continue }
            for key in ["command", "commandWindows"] {
                if let text = hook[key] as? String, text.contains(marker) { return true }
            }
        }
        return false
    }
}
