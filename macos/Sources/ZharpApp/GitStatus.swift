import Darwin
import Foundation
import ZharpCore

/// How a file differs from HEAD, as git reports it.
enum GitChangeKind {
    case modified, added, deleted, renamed, untracked, conflicted
}

/// One changed path in the working tree or the index.
struct GitFileChange {
    /// Repo relative, forward slashes, exactly as git prints it.
    let path: String

    /// Where the file came from, when `kind` is `.renamed`.
    let oldPath: String?

    let kind: GitChangeKind

    /// True when the change is staged rather than only in the working tree.
    let staged: Bool

    /// Lines added, counted from the diff. -1 until the counts are read.
    var added: Int

    /// Lines removed. -1 until the counts are read.
    var removed: Int

    init(path: String, oldPath: String? = nil, kind: GitChangeKind,
         staged: Bool = false, added: Int = -1, removed: Int = -1) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.staged = staged
        self.added = added
        self.removed = removed
    }

    var displayPath: String {
        guard let oldPath else { return path }
        return "\(oldPath) -> \(path)"
    }
}

/// A read-only view of the repository the session is standing in, built by
/// running the `git` the user already has.
///
/// Shelling out instead of linking a git library is the point, not a shortcut.
/// Zharp is a terminal, so git is installed by definition, and that git is the
/// one carrying the user's credentials, their includeIf rules, their
/// safe.directory list and whatever else they have configured. A bundled
/// implementation would eventually answer differently from the git running one
/// pane away, and quietly disagreeing with the shell in the same window is a
/// worse failure than costing a few milliseconds more.
///
/// Everything here reads. Nothing in this file stages, commits, checks out,
/// fetches or writes to the repository in any way.
///
/// A session over ssh is asked the same questions through `SshGitChannel`,
/// which runs the same read-only commands on the machine the user is actually
/// standing on. Every entry point takes a `SessionLocation` rather than a path
/// for exactly that reason: a path alone cannot say which computer it belongs
/// to, and on macOS a remote POSIX path is a perfectly ordinary local one, so
/// answering with the wrong machine is silent. That is the bug this replaced.
enum GitStatus {

    /// Long enough for a cold index on a large repository, short enough that a
    /// git that has stopped answering (a stale lock, a network filesystem gone
    /// quiet) cannot keep the panel waiting. One run shares this whole budget:
    /// the wait for the child and the wait for its pipes expire together.
    private static let timeout: TimeInterval = 10

    /// False when no usable git could be found, so a caller can say so rather
    /// than showing an empty panel that looks like a clean repository.
    static var isInstalled: Bool { executable != nil }

    // ------------------------------------------------------------ queries

    /// The repository root containing `workingDirectory`, or nil when it is not
    /// inside one.
    ///
    /// The path git prints is used verbatim as the working directory of every
    /// later call, so submodules and worktrees resolve to the repository the
    /// user is actually standing in. It is deliberately not standardised,
    /// resolved or run through realpath: git has already applied its own idea
    /// of the path (/tmp really is /private/tmp here), and every later call has
    /// to agree with it.
    static func discoverRepo(_ at: SessionLocation?) async -> SessionLocation? {
        guard let at, at.hasPath else { return nil }

        if at.isRemote {
            guard let remote = at.remote,
                  let channel = await SshGitChannels.channel(for: remote),
                  channel.isUsable
            else { return nil }

            // A remote shell reports ~/work as often as it reports the full
            // path, and git would go looking for a directory literally called
            // "~". The far end's own home, read once when the channel opened.
            let here = PosixPath.expandHome(at.path, home: channel.home)
            let root = await channel.runGit(in: here, ["rev-parse", "--show-toplevel"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return root.isEmpty ? nil : at.withPath(root)
        }

        // A session can outlive the directory it was started in; spawning a
        // process to be told so is wasted work.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: at.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        let result = await run(in: at, "rev-parse", "--show-toplevel")
        guard result.ok else { return nil }  // exit 128: not a repository

        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : at.withPath(root)
    }

    /// Why a machine reached over ssh cannot be read, or nil when it can.
    ///
    /// Shown instead of a file list, because "not a git repository" would be a
    /// guess when the truth is that nobody has been able to ask. Each of the
    /// answers here has a different thing the user can do about it, and the
    /// panel used to give all of them the same one: the last local repository
    /// it had seen, which is the single wrong answer that looks like a right
    /// one.
    static func remoteProblem(_ host: RemoteHost) async -> String? {
        guard SshGitChannels.enabled else {
            return "Reading git over ssh is turned off in Settings."
        }
        guard let channel = await SshGitChannels.channel(for: host) else {
            // The registry refuses two things: the switch being off, which was
            // just tested, and a host Zharp only heard about, which cannot be
            // dialled at all.
            return host.canConnect
                ? "Reading git over ssh is turned off in Settings."
                : "Zharp did not see the ssh command that got here, so it has no way to reach the same machine on its own."
        }
        return channel.isUsable ? nil : (channel.problem ?? "The connection could not be opened")
    }

    /// The branch name, or a short commit id when the head is detached, or nil
    /// when neither can be read (a repository with no commits yet).
    static func currentBranch(repoRoot: SessionLocation) async -> String? {
        let branch = await run(in: repoRoot, "rev-parse", "--abbrev-ref", "HEAD")
        guard branch.ok else { return nil }

        let name = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        if name != "HEAD" { return name }

        // Detached: name the commit instead, since "HEAD" tells nobody anything.
        let commit = await run(in: repoRoot, "rev-parse", "--short", "HEAD")
        let id = commit.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.ok && !id.isEmpty ? id : nil
    }

    /// Every path that differs from HEAD, staged and unstaged alike, in git's
    /// own order.
    ///
    /// `-z` is what makes this parseable at all. In its normal output git
    /// escapes awkward pathnames into C-style quoting ("a\tb", "caf\303\251"),
    /// whether it does so depends on core.quotePath, and the escaping is
    /// ambiguous for a name that genuinely contains a quote or a newline. With
    /// -z the separator is the one byte a pathname cannot contain and
    /// everything between separators is the raw name, which is why nothing
    /// below unquotes anything: there is nothing to unquote.
    static func changes(repoRoot: SessionLocation) async -> [GitFileChange] {
        let result = await run(in: repoRoot, "status", "--porcelain=v1", "-z",
                               "--untracked-files=all", "--no-renames")
        guard result.ok else { return [] }
        return parseStatus(result.output)
    }

    /// The unified diff for one path, against HEAD, covering the staged and the
    /// unstaged changes in a single stream.
    ///
    /// `staged` is part of the agreed signature and is deliberately not acted
    /// on. Diffing against HEAD is what makes a file that is staged and then
    /// modified again show all of its changes; asking for `--cached` because
    /// the status column said "staged" would show the panel half the file.
    ///
    /// An untracked path has nothing in HEAD to compare against, and this
    /// overload cannot tell tracked from untracked from its arguments, so it
    /// works it out when the first diff comes back empty.
    /// `diff(repoRoot:change:)` knows the kind up front and skips all of that.
    static func diff(repoRoot: SessionLocation, path: String, staged: Bool) async -> String? {
        let tracked = await run(in: repoRoot, "diff", "HEAD", "--no-color", "--", path)
        if tracked.ok && !tracked.output.isEmpty { return tracked.output }

        // Empty means one of two opposite things: the path is untracked, or it
        // stopped differing between the listing and now (the user reverted it
        // while the panel was open). Ask instead of guessing, because showing a
        // reverted file as one long addition is worse than the extra launch.
        let known = await run(in: repoRoot, "ls-files", "--error-unmatch", "-z", "--", path)
        // There is no exit status over ssh, so tracked-ness is read off the
        // output instead: ls-files prints the path when it knows it and nothing
        // at all when it does not.
        let isTracked = repoRoot.isRemote ? !known.output.isEmpty : known.ok
        if isTracked { return tracked.ok ? "" : nil }

        return await untrackedDiff(repoRoot: repoRoot, path: path)
    }

    /// The diff for one listed change, and the entry point the panel should
    /// use: knowing the kind sends an untracked file straight to the empty-file
    /// comparison instead of paying for a diff against HEAD that can only come
    /// back empty.
    static func diff(repoRoot: SessionLocation, change: GitFileChange) async -> String? {
        if change.kind == .untracked {
            return await untrackedDiff(repoRoot: repoRoot, path: change.path)
        }
        let result = await run(in: repoRoot, "diff", "HEAD", "--no-color", "--", change.path)
        return result.ok ? result.output : nil
    }

    /// Added and removed line counts for every tracked path that differs from
    /// HEAD, in one call.
    ///
    /// One `git diff --numstat` replaces one `git diff` per changed file. On a
    /// tree with fifty changes that is fifty process launches traded for one,
    /// which is the difference between totals that are simply there and totals
    /// that trickle in.
    ///
    /// Untracked files are absent, because git has nothing to compare them
    /// against: `countUntracked(repoRoot:path:)` covers those. Binary files
    /// report "-" for both numbers and land here as (0, 0), since the line
    /// count of a binary is not a number worth showing anyone.
    static func counts(repoRoot: SessionLocation) async -> [String: (added: Int, removed: Int)] {
        var totals: [String: (added: Int, removed: Int)] = [:]

        // --no-renames matches `changes` above. With rename detection on, a
        // renamed pair is written as "added\tremoved\t\0oldpath\0newpath\0":
        // the counts record has an empty path and the two path records have no
        // counts, so a rename would silently contribute nothing to the totals.
        // Off, the pair is a delete plus an add and the keys line up with the
        // rows the panel is showing.
        let result = await run(in: repoRoot, "diff", "--numstat", "-z", "--no-renames", "HEAD")
        guard result.ok else { return totals }

        // Records are "added\tremoved\tpath", NUL terminated. -z again, so the
        // path is raw and these keys match `changes` byte for byte, which is
        // the only reason a plain dictionary lookup finds them: no lowercasing
        // and no Unicode normalisation, or a decomposed name on APFS misses.
        for record in result.output.split(separator: "\0", omittingEmptySubsequences: true) {
            // maxSplits, because a pathname is allowed to contain a tab and
            // only the first two fields are ever numbers.
            let parts = record.split(separator: "\t", maxSplits: 2,
                                     omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }

            let path = String(parts[2])
            if path.isEmpty { continue }
            totals[path] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
        return totals
    }

    /// An untracked file's whole content is what a diff would show as added, so
    /// its line count is its added count. Read directly rather than through
    /// git, which would need one process per new file to say the same thing.
    static func countUntracked(repoRoot: SessionLocation, path: String) async -> Int {
        if repoRoot.isRemote {
            // Reading the file back over the wire to count its newlines would
            // move the whole file to put one small grey number in a list row.
            // wc is on every machine that has a shell.
            guard let remote = repoRoot.remote,
                  let channel = await SshGitChannels.channel(for: remote),
                  channel.isUsable
            else { return 0 }

            // "     12 path" on BSD, "12 path" on GNU, so the number is the
            // first field either way.
            let answer = await channel.run(in: repoRoot.path, ["wc", "-l", "--", path])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let field = answer.prefix { !$0.isWhitespace }
            return Int(field) ?? 0
        }

        let full = (repoRoot.path as NSString).appendingPathComponent(path)
        let url = URL(fileURLWithPath: full)
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return 0 }

            // Reading a very large new file line by line to put a number in a
            // title bar is not worth what it costs.
            guard let size = values.fileSize, size <= 4 * 1024 * 1024 else { return 0 }

            return countLines(in: try Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            // Unreadable, or gone between the status listing and now.
            return 0
        }
    }

    /// Counts the +/- lines of a unified diff, ignoring the `+++` and `---`
    /// file headers, which begin with the same characters and are not content.
    /// The headers are tested first for exactly that reason.
    static func countLines(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        return (added, removed)
    }

    // ------------------------------------------------------------ parsing

    private static func parseStatus(_ output: String) -> [GitFileChange] {
        var changes: [GitFileChange] = []

        // A record is "XY <path>": index column, worktree column, a space that
        // is skipped rather than checked, then the path to the end of the
        // record. This walks an index instead of iterating because a rename
        // record is followed by a second record holding the old path.
        // --no-renames means that cannot happen today, but the parser stays
        // correct if the flag is ever dropped, and a parser that loses its
        // place mislabels every file after the rename.
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var position = 0

        while position < records.count {
            let record = records[position]
            position += 1
            guard record.count >= 4 else { continue }

            let index = record[record.startIndex]
            let tree = record[record.index(after: record.startIndex)]
            let path = String(record.dropFirst(3))
            if path.isEmpty { continue }

            if index == "?" && tree == "?" {
                changes.append(GitFileChange(path: path, kind: .untracked))
                continue
            }

            // The unmerged set: a U on either side, plus both-added and
            // both-deleted, which git reports without a U at all.
            if index == "U" || tree == "U"
                || (index == "A" && tree == "A") || (index == "D" && tree == "D") {
                changes.append(GitFileChange(path: path, kind: .conflicted))
                continue
            }

            // A path can be staged AND modified again in the working tree. It
            // is listed once, as staged, because that is the state the next
            // commit would capture; the diff shown for it covers both halves.
            let staged = index != " " && index != "?"
            let code = staged ? index : tree

            // R and C both name a source file in the next record, so both have
            // to consume it whether or not the kinds are told apart.
            var oldPath: String?
            if (code == "R" || code == "C") && position < records.count {
                oldPath = String(records[position])
                position += 1
            }

            let kind: GitChangeKind
            switch code {
            case "A": kind = .added
            case "D": kind = .deleted
            case "R", "C": kind = .renamed
            default: kind = .modified  // M, T (typechange), and anything new
            }

            changes.append(GitFileChange(path: path, oldPath: oldPath,
                                         kind: kind, staged: staged))
        }

        return changes
    }

    /// An untracked file is compared with the empty file, which prints it as
    /// one long addition: what "what changed" means for a file that is
    /// entirely new.
    private static func untrackedDiff(repoRoot: SessionLocation, path: String) async -> String {
        // --no-index exits 1 when the two files differ, which is the whole
        // reason for asking, so its exit code is not a failure signal here.
        let result = await run(in: repoRoot, allowFailure: true,
                               "diff", "--no-index", "--no-color", "--", "/dev/null", path)
        return result.output
    }

    /// Counts lines the way a line reader would: CRLF, LF and a bare CR each
    /// end one line, an empty file is 0, and a file ending in a newline is N
    /// rather than N + 1.
    private static func countLines(in data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            var lines = 0
            var pending = false  // bytes seen since the last terminator
            var i = 0
            while i < raw.count {
                let byte = raw[i]
                i += 1
                if byte == 0x0A {  // LF
                    lines += 1
                    pending = false
                } else if byte == 0x0D {  // CR, and CRLF is one terminator
                    lines += 1
                    pending = false
                    if i < raw.count && raw[i] == 0x0A { i += 1 }
                } else {
                    pending = true
                }
            }
            return pending ? lines + 1 : lines
        }
    }

    // ------------------------------------------------------------ running git

    private struct GitResult {
        let ok: Bool
        let output: String
        let error: String
    }

    /// git always runs off the main thread. The panel refreshes on a timer and
    /// asks from the main actor, and a read-only side panel is the last thing
    /// in the app that should ever be able to stall the cursor. Concurrent
    /// because a single run parks one thread on the child's exit and one on
    /// each of its two pipes.
    private static let queue = DispatchQueue(label: "app.zharp.git", qos: .utility,
                                             attributes: .concurrent)

    private static let systemGit = "/usr/bin/git"

    /// Resolved once. PATH does not change under a running app, so probing the
    /// filesystem before every one of the panel's calls would buy nothing.
    private static let executable: String? = {
        let found = locateGit()
        if found == nil {
            App.log("git was not found, so the changes panel has nothing to report.")
        }
        return found
    }()

    /// Finds git the way a login shell would, which matters here because an app
    /// launched from the Dock inherits a bare PATH (/usr/bin:/bin:/usr/sbin:
    /// /sbin) and never sees Homebrew.
    ///
    /// Homebrew comes first for the same reason this file shells out at all: a
    /// user who installed a newer git expects the panel to agree with the git
    /// their shell runs. /usr/bin/git is skipped entirely, and the real binary
    /// behind it used instead, because without the Command Line Tools that path
    /// is only a stub whose one effect is to pop the system "install developer
    /// tools" dialog. No environment variable suppresses that dialog, and a
    /// panel refreshing on a timer would raise it again and again.
    private static func locateGit() -> String? {
        let manager = FileManager.default
        let preferred = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        for candidate in preferred where manager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // The session's own PATH, when the app was started from a shell that
        // has one, covering installs in neither of the usual places.
        if let onPath = ShellDiscovery.findOnPath("git"), onPath != systemGit {
            return onPath
        }
        let developerTools = ["/Library/Developer/CommandLineTools/usr/bin/git",
                              "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return developerTools.first { manager.isExecutableFile(atPath: $0) }
    }

    /// The one fork between the two machines, so every question above is asked
    /// once and answered by whichever computer the session is standing on.
    private static func run(in at: SessionLocation, allowFailure: Bool = false,
                            _ arguments: String...) async -> GitResult {
        if at.isRemote {
            return await runRemote(at, arguments)
        }
        return await runLocal(in: at.path, allowFailure: allowFailure, arguments)
    }

    /// Runs git on the far end of an ssh connection.
    ///
    /// There is no exit status here, deliberately. Carrying one back would need
    /// a temporary file on the user's server for every poll, and no caller in
    /// this file tells "git failed" from "git printed nothing": a directory
    /// that is not a repository, a file that is not there and a clean tree all
    /// mean an empty answer, which is what the panel shows either way. Whether
    /// the machine can be reached at all is a different question with a
    /// different answer, and `remoteProblem` is where it is asked.
    private static func runRemote(_ at: SessionLocation, _ arguments: [String]) async -> GitResult {
        guard let remote = at.remote,
              let channel = await SshGitChannels.channel(for: remote),
              channel.isUsable
        else { return GitResult(ok: false, output: "", error: "no connection") }

        // Not hardened here. The channel rewrites any argv beginning with git,
        // and refuses a subcommand that is not on its read-only list, so the
        // guarantee holds for a caller this file never sees.
        let output = await channel.runGit(in: at.path, arguments)
        return GitResult(ok: true, output: output, error: "")
    }

    private static func runLocal(in workingDirectory: String, allowFailure: Bool,
                                 _ arguments: [String]) async -> GitResult {
        let handle = RunHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: execute(workingDirectory, allowFailure,
                                                           arguments, handle))
                }
            }
        } onCancel: {
            // The panel starts a fresh refresh every couple of seconds and drops
            // the one before it; there is no point leaving a git behind to
            // finish work nobody will read.
            handle.stop()
        }
    }

    /// Wraps a command in the settings that keep "read-only" true.
    ///
    /// git reads the config of whichever repository it is pointed at, and some
    /// of that config is commands git will run: `core.fsmonitor` is run by
    /// `status`, and `diff.external` (plus the per-driver `diff.<name>.command`
    /// that a `.gitattributes` line can select) is run by `diff`, including
    /// `diff --no-index`. This panel follows the active session's working
    /// directory and re-reads it on a timer, so without these a `cd` into a
    /// repository carrying a hostile `.git/config` would be enough to run its
    /// commands, over and over, with nobody having typed anything. The shell
    /// one pane away would run them too, but only when the user asked it to,
    /// and a command that runs is a command that can write: the guarantee at
    /// the top of this file holds only while nothing here executes repository
    /// config.
    ///
    /// Nothing is lost by refusing. The panel wants git's own unified diff
    /// text, and an external differ or a textconv filter exists precisely to
    /// replace it with something else.
    private static func harden(_ arguments: [String]) -> [String] {
        // Applies to every subcommand. Empty means unset, whatever the
        // repository, the user's global config or an includeIf rule said.
        var argv = ["-c", "core.fsmonitor=", "-c", "diff.external="]

        guard let subcommand = arguments.first else { return argv }
        argv.append(subcommand)
        // `--no-ext-diff` is the half `diff.external=` cannot cover: a
        // repository may define any number of named drivers, so they can only
        // be turned off as a class. Both are accepted in --no-index mode.
        if subcommand == "diff" {
            argv.append(contentsOf: ["--no-ext-diff", "--no-textconv"])
        }
        argv.append(contentsOf: arguments.dropFirst())
        return argv
    }

    private static func execute(_ workingDirectory: String, _ allowFailure: Bool,
                                _ arguments: [String], _ handle: RunHandle) -> GitResult {
        guard let executable else {
            return GitResult(ok: false, output: "", error: "git not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Arguments are handed over as an argv array rather than a command
        // line, so nothing here is quoted or escaped and a path holding spaces,
        // quotes or a newline arrives as one argument exactly as git printed it.
        process.arguments = harden(arguments)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Inherit the environment (git needs HOME and PATH to find the user's
        // config and their helpers) and then close the doors git could stop and
        // knock on.
        var environment = ProcessInfo.processInfo.environment
        // A GUI process has nowhere to draw a credential prompt and nothing to
        // answer it with, so without this git would sit there until the timeout
        // with the user seeing no reason why.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Never take index.lock for a read: the panel refreshes on a timer and
        // must not end up fighting the shell's own git for it.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Git Credential Manager, when it is installed, is told not to open a
        // window of its own.
        environment["GCM_INTERACTIVE"] = "never"
        // Every path below is a real name git just printed, never a pattern the
        // user typed, and `--` alone does not make git read it as one. After
        // the separator git still parses a leading colon as pathspec magic, so
        // a file genuinely named ":(exclude)secret" turns its own diff request
        // into "everything except me" and the panel shows one file's row with
        // every other file's diff under it. Literal means a name is a name.
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        process.environment = environment

        // The app's own stdin is whatever launchd handed it. /dev/null means a
        // git that decides to read gets an immediate EOF instead of blocking.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return GitResult(ok: false, output: "", error: "\(error)")
        }

        // The child leads its own process group where the kernel still allows
        // it, so a timeout can take down whatever git spawned (a hook, a
        // credential helper) instead of only git. Losing the race with the
        // child's exec is normal and simply means the group kill is skipped.
        _ = setpgid(process.processIdentifier, process.processIdentifier)

        guard handle.adopt(process) else {
            terminate(process)
            return GitResult(ok: false, output: "", error: "git cancelled")
        }

        // Both pipes are drained on their own threads, before anything waits on
        // the child. `git diff` outgrows the pipe buffer easily, and a child
        // blocked writing into a pipe nobody is reading never exits: waiting
        // first and reading afterwards is the classic way to deadlock this.
        let drained = DispatchGroup()
        let out = PipeDrain(outPipe, on: queue, group: drained)
        let errors = PipeDrain(errPipe, on: queue, group: drained)

        // One deadline for the whole run, so waiting for the child and then for
        // its pipes cannot add up to more than the budget.
        let deadline = DispatchTime.now() + timeout
        if exited.wait(timeout: deadline) == .timedOut {
            handle.stop()
            // The two drains are abandoned deliberately. They end on their own
            // when the pipes close, and the caller is owed an answer now.
            return GitResult(ok: false, output: "", error: "git timed out")
        }
        handle.release()

        // Normally instant, since the pipes reach EOF as the child dies.
        // Bounded all the same: a grandchild that inherited them holds them
        // open for as long as it likes.
        _ = drained.wait(timeout: deadline)

        // Output comes back either way; only the flag changes, because
        // --no-index reports "these differ" as a non-zero exit.
        let ok = allowFailure || process.terminationStatus == 0
        return GitResult(ok: ok, output: out.text, error: errors.text)
    }

    /// SIGKILL rather than a polite SIGTERM: this only runs once git has
    /// overrun its budget or nobody is waiting for its answer any more, and in
    /// both cases a signal the process might choose to handle is no use.
    private static func terminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        // Only when the child genuinely leads its own group, so this can never
        // reach back into Zharp itself. When it does, everything git started
        // goes with it.
        let group = getpgid(pid)
        if group == pid && group != getpgrp() {
            Darwin.kill(-group, SIGKILL)
        }
        Darwin.kill(pid, SIGKILL)
    }

    /// The meeting point between a Task that can be cancelled and a Foundation
    /// process that knows nothing about Swift concurrency. Cancellation can
    /// arrive before the child exists or long after it has gone, so both sides
    /// come through here under a lock.
    private final class RunHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        /// Takes charge of a freshly started child. False when cancellation
        /// beat it here, in which case the caller kills what it just started.
        func adopt(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if stopped { return false }
            self.process = process
            return true
        }

        /// The child finished on its own; there is nothing left to cancel.
        func release() {
            lock.lock()
            process = nil
            lock.unlock()
        }

        func stop() {
            lock.lock()
            let running = process
            process = nil
            stopped = true
            lock.unlock()
            if let running { GitStatus.terminate(running) }
        }
    }

    /// One pipe being emptied on a background thread while git is still running.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        init(_ pipe: Pipe, on queue: DispatchQueue, group: DispatchGroup) {
            let handle = pipe.fileHandleForReading
            queue.async(group: group) { [self] in
                let data = handle.readDataToEndOfFile()
                lock.lock()
                bytes = data
                lock.unlock()
            }
        }

        /// Decoded leniently on purpose. A pathname is bytes, not text, and git
        /// hands back whatever the filesystem holds; replacing the odd invalid
        /// byte keeps the rest of a status listing usable, where insisting on
        /// valid UTF-8 would throw the whole listing away over one file.
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
