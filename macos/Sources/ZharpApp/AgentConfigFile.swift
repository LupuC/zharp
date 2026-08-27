import Foundation

/// The read-modify-write half of every agent integration: a JSON file that
/// belongs to somebody else and has to come back with everything they put in
/// it still in it.
///
/// The Windows build writes this out once per integration. Here it is shared,
/// because it is the part where being wrong costs a user their agent
/// configuration, and one copy is one thing to get right and one thing to
/// re-read when somebody doubts it.
enum AgentConfigFile {

    enum Failure: Error {
        /// The file parsed, but into something other than a JSON object. Not a
        /// file we can merge into, and not one to overwrite either.
        case notAnObject
    }

    /// Parses the file. nil means there is nothing to merge with, which is only
    /// ever a missing or empty file.
    ///
    /// Anything that does not parse throws, and that distinction is the whole
    /// point of this function. A caller treating a parse failure as "no file
    /// yet" would write a hooks-only document over a settings file somebody has
    /// spent a year on. Throwing aborts the sync with the file untouched.
    ///
    /// One consequence worth stating plainly: JSONSerialization is stricter
    /// than the parser the Windows build uses, which is configured to skip
    /// comments and tolerate trailing commas. A settings.json with a comment in
    /// it is accepted by Claude Code and rejected here, so the integration
    /// turns itself off for that user rather than installing. That is the right
    /// end of the trade. Nothing round trips a comment, so the alternative is
    /// not "parse it anyway", it is "parse it and then silently delete their
    /// comments on the way out".
    static func read(_ url: URL) throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }

        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let root = parsed as? [String: Any] else { throw Failure.notAnObject }
        return root
    }

    /// The file a path finally names, following a symlink on the end of it.
    ///
    /// Worth doing before any write. A `settings.json` looked after by a
    /// dotfile manager (stow, chezmoi, yadm) is usually a symlink into a
    /// repository, and an atomic write does not write *through* a link, it
    /// REPLACES what it is handed. That left the link gone, the repository copy
    /// silently orphaned so every later edit there was ignored, and the new
    /// regular file carrying the link's own 0755 instead of the 0600 the user
    /// had - on a file whose `env` block routinely holds API tokens.
    ///
    /// Bounded, because a link that points at itself must not spin here.
    private static func resolvingLink(_ url: URL) -> URL {
        let files = FileManager.default
        var current = url
        for _ in 0..<8 {
            guard let target = try? files.destinationOfSymbolicLink(atPath: current.path) else {
                return current // not a link: this is the real file
            }
            current = URL(fileURLWithPath: target,
                          relativeTo: current.deletingLastPathComponent()).standardizedFileURL
        }
        return current
    }

    /// Replaces the file in one step, keeping a copy of what was there the
    /// first time Zharp ever touches it.
    static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // Whatever the user actually keeps their settings in.
        let file = resolvingLink(url)

        // Once, ever. This is a file the user edits by hand and depends on
        // daily; it should survive us being wrong about it.
        //
        // Kept beside the name Zharp was given rather than beside the link's
        // target, so a backup never appears as an untracked file inside
        // somebody's dotfiles repository. Copied from the resolved file, so it
        // is a real copy and not a second symlink to the thing being rewritten.
        let backup = URL(fileURLWithPath: url.path + ".zharp-backup")
        if FileManager.default.fileExists(atPath: file.path),
           !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: file, to: backup)
        }

        // Sorted keys because a Swift dictionary has no order to preserve: the
        // user's own key order is lost either way, and sorting at least means
        // the second write does not reshuffle the file for no reason. Slashes
        // unescaped so the paths written here read as paths.
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        // .atomic writes beside the file and renames over the top, so a crash
        // halfway through leaves the old file whole instead of half a new one.
        // It also carries the original file's permissions across, which matters
        // for a config somebody has deliberately kept at 0600 - and which only
        // works because `file` is the regular file rather than a link to it.
        try data.write(to: file, options: .atomic)
    }

    /// Deep structural equality, for asking whether a hook already in the file
    /// is exactly the one `connect()` would write. NSDictionary compares nested
    /// arrays and dictionaries all the way down, which is what makes a changed
    /// timeout or a moved script path repair itself.
    static func matches(_ node: Any?, _ wanted: [String: Any]) -> Bool {
        (wanted as NSDictionary).isEqual(node)
    }

    /// Quotes a path for a `/bin/sh` command line.
    ///
    /// Only Codex needs this: it takes a command line rather than an argument
    /// list, so the app bundle path goes through a shell. Single quotes rather
    /// than double, because double quotes still leave `$`, a backtick and a
    /// backslash live, and "Zharp.app" is not the only thing that can end up in
    /// this path.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
