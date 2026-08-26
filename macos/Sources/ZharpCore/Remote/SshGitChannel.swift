import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A second, quiet ssh connection to a machine the user is already on, used to
/// read git there.
///
/// It is a long-lived `ssh host sh` with commands written into its stdin,
/// rather than one `ssh host git ...` per question, because the panel asks
/// several questions every few seconds and an ssh handshake costs a few hundred
/// milliseconds. One connection per host turns that into one round trip per
/// question. OpenSSH's own answer to this is ControlMaster, which Zharp does
/// not set up on the user's behalf: a control socket outlives the process that
/// made it and changes how their own ssh behaves afterwards, so the
/// multiplexing is done here instead, where it dies with the app.
///
/// It can never prompt. BatchMode is forced on, ahead of any option the user
/// passed, so a host needing a password or a hardware token fails immediately
/// and says so, rather than blocking on a prompt drawn in a window that has
/// nowhere to show it. Everything it runs is read-only.
public final class SshGitChannel: @unchecked Sendable {

    /// The far end's home directory, so a ~ in a path can be expanded before it
    /// is sent. git treats ~ as an ordinary directory name.
    public var home: String? { state.locked { openHome } }

    /// Why this host cannot be read, in words worth showing.
    public var problem: String? { state.locked { openProblem } }

    public var isUsable: Bool { state.locked { !dead && openProblem == nil } }

    // ---------------------------------------------------------------- budgets

    /// Long enough for a busy remote to answer a cold `git status`, short
    /// enough that a wedged connection releases the panel.
    private static let callTimeout: TimeInterval = 15

    /// The handshake is one `printf` on the far end, so all of this is the
    /// connection itself: DNS, TCP, the key exchange, and a jump host in the
    /// middle repeating all three.
    private static let handshakeTimeout: TimeInterval = 20

    /// How long to let ssh's own complaint arrive after its stdout has closed.
    /// The two pipes end at almost the same moment and in either order, and
    /// reporting "the connection closed" when ssh took another millisecond to
    /// say "Permission denied" would throw away the only useful sentence.
    private static let stderrGrace: TimeInterval = 0.2

    // ------------------------------------------------------------------ state

    /// Everything on this connection happens here, one command at a time. The
    /// stream carries no request ids, so two overlapping calls would read each
    /// other's frames; a serial queue is the whole of the mutual exclusion, and
    /// it also keeps the blocking reads off whatever thread asked.
    private let queue = DispatchQueue(label: "app.zharp.ssh", qos: .utility)

    /// Named separately from `queue` so a stalled answer cannot also stall the
    /// draining of ssh's stderr, which is where the reason for the stall is.
    private let errorQueue = DispatchQueue(label: "app.zharp.ssh.stderr", qos: .utility)

    private let state = NSLock()
    private var openHome: String?
    private var openProblem: String?
    private var dead = false
    private var disposed = false

    /// Every frame from this connection ends with this line. One per channel
    /// rather than one per call, because it never has to be guessed at: the
    /// reader knows which marker it wrote.
    private let marker = "ZHARP-END-" + UUID().uuidString
        .replacingOccurrences(of: "-", with: "").prefix(8).lowercased()

    private var process: Process?

    /// All three are held for their whole life, including the two nothing reads
    /// through again: a Pipe closes its descriptors when it goes, and the
    /// reader and the stderr pump hold bare descriptors rather than the handles
    /// that own them.
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    private var reader: LineReader?
    private var errors: StderrPump?

    private init() {}

    // ------------------------------------------------------------- connecting

    /// Which ssh to run. The one macOS ships unless ZHARP_SSH names another,
    /// which is also how the smoke tests point the whole transport at a local
    /// shell and exercise it with no server to connect to.
    private static var sshProgram: String? {
        if let custom = ProcessInfo.processInfo.environment["ZHARP_SSH"], !custom.isEmpty {
            // Taken as given when it names a file, so a stub can live anywhere.
            if custom.contains("/") {
                return FileManager.default.isExecutableFile(atPath: custom) ? custom : nil
            }
            return search(path: custom)
        }
        // PATH first, so a user who installed a newer OpenSSH gets the one
        // their shell runs; /usr/bin/ssh is the fallback because an app started
        // from the Dock inherits a PATH that may not mention much else.
        return search(path: "ssh") ?? "/usr/bin/ssh"
    }

    private static func search(path name: String) -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
        for directory in directories {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: String(candidate)) {
                return String(candidate)
            }
        }
        return nil
    }

    /// Connects, authenticates, and agrees that the far end can do the two
    /// things this needs: run a shell, and base64 its output.
    ///
    /// Never throws and never returns nil. A connection that could not be made
    /// is still a channel, because it carries why, and why is the only thing
    /// worth saying about this host until the user changes something.
    public static func connect(to host: RemoteHost) async -> SshGitChannel {
        let channel = SshGitChannel()

        // The rule the whole feature rests on, and the reason this asks for an
        // invocation rather than for a host name. A machine Zharp only heard
        // about, through OSC 7 or a window title, is a name that arrived over
        // the wire from a program on another computer, and it has no invocation
        // to offer: SshTarget.parse is the only thing that makes one, out of a
        // command line read at a local prompt. There is nothing to forget to
        // check here, because a reported host has nothing to hand over.
        guard let invocation = host.invocation else {
            channel.fail("Zharp did not see the ssh command that got here, "
                         + "so it has no way to reach the same machine on its own.")
            return channel
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            channel.queue.async {
                channel.start(invocation)
                channel.handshake()
                continuation.resume()
            }
        }
        return channel
    }

    private func start(_ invocation: SshInvocation) {
        guard let program = Self.sshProgram else {
            fail("ssh is not installed on this machine")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)

        // Ours first: OpenSSH keeps the first value it is given for an option,
        // so these win over anything the user's own command or their ssh config
        // sets. Never prompting is not a preference, it is the only safe
        // behaviour for a connection the user did not ask for and cannot see.
        var argv = ["-T",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    "-o", "LogLevel=ERROR",
                    // A LocalCommand runs on THIS machine, after the
                    // connection succeeds, through a shell. Nothing about
                    // reading git wants one, and this connection is opened by
                    // a timer rather than by a person, so it is turned off
                    // here where first-wins makes it final. `SshTarget.parse`
                    // already refuses to carry one off a command line; this is
                    // the half that covers an ssh_config the user has
                    // forgotten about.
                    "-o", "PermitLocalCommand=no",
                    // Same argument for forwards: a second connection that
                    // silently re-opens the user's tunnels is a surprise at
                    // best, and on a host that refuses a duplicate bind it is
                    // a failure they cannot explain.
                    "-o", "ClearAllForwardings=yes"]
        // The user's own connection flags, then the destination, then the one
        // program this runs. Note what is deliberately absent: nothing here
        // relaxes host key checking. An unknown host fails and the panel says
        // to accept the key in the terminal, because a terminal is a place a
        // person can look at a fingerprint and decide.
        argv.append(contentsOf: invocation.arguments)
        argv.append("sh")
        process.arguments = argv

        var environment = ProcessInfo.processInfo.environment
        // BatchMode already refuses every prompt. This closes the other door:
        // an askpass helper is a window, and a window is the thing a GUI
        // process must never open on a connection nobody asked for.
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["SSH_ASKPASS"] = nil
        process.environment = environment

        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            fail("ssh could not be started: \(error.localizedDescription)")
            return
        }

        // The child leads its own process group where the kernel still allows
        // it, so tearing the channel down takes whatever ssh spawned (a
        // ProxyCommand, an askpass that should not exist) with it rather than
        // only ssh. Losing the race with the child's exec is normal and simply
        // means the group kill is skipped.
        _ = setpgid(process.processIdentifier, process.processIdentifier)

        // Writing to a pipe whose reader has gone raises SIGPIPE, which by
        // default kills the whole app. Per-descriptor rather than
        // signal(SIGPIPE, SIG_IGN), because a library has no business changing
        // a process-wide signal disposition.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        self.process = process
        self.inputPipe = input
        self.outputPipe = output
        self.errorPipe = error
        self.reader = LineReader(output.fileHandleForReading.fileDescriptor)
        self.errors = StderrPump(error.fileHandleForReading.fileDescriptor, on: errorQueue)
    }

    private func handshake() {
        guard process != nil else { return }

        // $HOME so a ~ can be expanded here, and a base64 check because the
        // whole transport depends on it: base64 is what keeps a filename
        // containing a newline from being read as the end of an answer.
        guard write("printf 'ZHARP-HOME %s\\n' \"$HOME\"; "
                    + "if command -v base64 >/dev/null 2>&1; then printf 'ZHARP-OK\\n'; "
                    + "else printf 'ZHARP-NO-BASE64\\n'; fi\n") else { return }

        let deadline = Date().addingTimeInterval(Self.handshakeTimeout)
        while true {
            switch reader?.next(by: deadline) ?? .closed {
            case .line(let line):
                if line.hasPrefix("ZHARP-HOME ") {
                    state.locked {
                        openHome = String(line.dropFirst("ZHARP-HOME ".count))
                            .trimmingCharacters(in: .whitespaces)
                    }
                } else if line.hasPrefix("ZHARP-NO-BASE64") {
                    fail("The remote shell has no base64, so its output cannot be read safely")
                    return
                } else if line.hasPrefix("ZHARP-OK") {
                    return
                }
                // Anything else is a banner or a motd on stdout, which plenty
                // of hosts print and none of them mean as an answer.

            case .closed:
                // ssh died, or `sh` was never there to run: a Windows server
                // over ssh reaches exactly this point.
                fail(explain(errors?.drained(within: Self.stderrGrace) ?? ""))
                return

            case .timedOut:
                fail("The connection did not finish opening in time")
                return
            }
        }
    }

    // ---------------------------------------------------------------- running

    /// Runs one read-only command in a directory on the far end and returns
    /// what it wrote to stdout.
    ///
    /// Empty means it produced nothing, whether that is because the directory
    /// is not a repository, the file is not there, or the command failed. Every
    /// caller treats those the same way, so no exit status is carried back:
    /// doing so would need a temporary file on the user's server for every
    /// poll. Whether the machine can be reached at all is a different question,
    /// answered by `problem`.
    public func run(in directory: String, _ argv: [String]) async -> String {
        guard isUsable, !argv.isEmpty, !directory.isEmpty else { return "" }

        // Cancellation is honoured here and nowhere after here. The panel drops
        // a refresh and starts another every few seconds, so this is the common
        // case and it costs nothing: nothing has been written, so the stream is
        // still at a frame boundary. Abandoning a read once the command is out
        // would leave that answer in the pipe for the next call to read as its
        // own, and every frame after it would be one behind, forever.
        if Task.isCancelled { return "" }

        // git gets the same treatment it gets locally, wherever the argv was
        // assembled. Applying it here rather than trusting callers is
        // deliberate: this is the one point every git command on this machine's
        // behalf passes through, and a caller that builds its own argv would
        // otherwise lose the hardening silently, on a repository nobody has
        // even cloned.
        var command = argv
        if isGit(argv[0]) {
            guard let hardened = Self.hardenedGit(argv) else { return "" }
            command = hardened
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.async {
                continuation.resume(returning: self.send(in: directory, command))
            }
        }
    }

    /// The same thing for git, spelled so the caller does not have to remember
    /// to say "git" first. Callers still put `--` before any pathspec.
    public func runGit(in directory: String, _ arguments: [String]) async -> String {
        await run(in: directory, ["git"] + arguments)
    }

    /// One command out, one frame back. Runs on `queue`, so it is the only
    /// thing touching the stream while it does.
    private func send(in directory: String, _ argv: [String]) -> String {
        guard isUsable, let reader else { return "" }

        // The marker's printf sits outside the braces on purpose: the frame is
        // terminated even when the cd fails or the command does not exist, so
        // there is no path where a call waits for a marker nobody printed. The
        // leading \n closes the base64 line that `tr` left unterminated, which
        // is also what puts the marker on a line of its own when the payload is
        // empty.
        var command = "{ cd " + ShellWords.quote(directory) + " 2>/dev/null && "
        if isGit(argv[0]) {
            // The environment half of the local hardening. Nothing over here
            // has a terminal to prompt on, nothing may take index.lock for a
            // read, and a file genuinely named ":(exclude)secret" is a file
            // name rather than a pathspec that quietly means "everything else".
            command += "GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_LITERAL_PATHSPECS=1 "
        }
        command += argv.map(ShellWords.quote).joined(separator: " ")
        command += " 2>/dev/null | base64 | tr -d '\\n'; }; printf '\\n%s\\n' "
        command += ShellWords.quote(marker) + "\n"

        guard write(command) else { return "" }

        let deadline = Date().addingTimeInterval(Self.callTimeout)
        var payload = ""
        while true {
            switch reader.next(by: deadline) {
            case .line(let line):
                if line == marker {
                    // Byte equal, never a prefix: the payload cannot contain
                    // the marker (base64 has no room for it), but a banner
                    // could, and a banner is not the end of an answer.
                    guard !payload.isEmpty,
                          let bytes = Data(base64Encoded: payload) else { return "" }
                    // Bytes then UTF-8, leniently. A pathname is bytes rather
                    // than text and the far end hands back whatever its
                    // filesystem holds; one bad byte should cost one odd
                    // character, not the whole status listing.
                    return String(decoding: bytes, as: UTF8.self)
                }
                // `tr -d '\n'` already made this one line. Concatenating is in
                // case a base64 elsewhere wraps anyway.
                payload += line

            case .closed:
                // The far end hung up mid answer. Nothing here can tell where
                // the next frame would start, so the channel goes rather than
                // the answer.
                fail(explain(errors?.drained(within: Self.stderrGrace) ?? ""))
                return ""

            case .timedOut:
                // A half-read frame poisons every frame after it, so this
                // destroys the connection instead of reusing it. The next poll
                // opens a fresh one.
                fail("The remote stopped answering")
                dispose()
                return ""
            }
        }
    }

    private func isGit(_ program: String) -> Bool {
        program == "git" || program.hasSuffix("/git")
    }

    /// The read-only settings that make "it never writes" true of a repository
    /// nobody vetted, and the list of subcommands allowed to run at all.
    ///
    /// git runs commands out of the config of whichever repository it is
    /// pointed at: `core.fsmonitor` is run by `status`, and `diff.external`
    /// (plus any per-driver `diff.<name>.command` a `.gitattributes` line can
    /// select) is run by `diff`. The panel follows the session's directory and
    /// re-reads it on a timer, so a `cd` into a repository carrying a hostile
    /// config would otherwise be enough to run its commands, over and over,
    /// with nobody having typed anything. A repository on someone else's server
    /// is exactly as hostile as a local one and arguably more so, since the
    /// user did not clone it and cannot see it.
    ///
    /// Nil for a subcommand that is not on the list. The list is generous with
    /// reads and holds nothing that writes, so the guarantee at the top of this
    /// file survives an edit to a caller that this file never sees.
    private static func hardenedGit(_ argv: [String]) -> [String]? {
        var index = 1
        var options: [String] = []
        while index < argv.count {
            let token = argv[index]
            if token == "-c" || token == "-C" || token == "--namespace" {
                // These take a separate value, which is not a subcommand.
                options.append(token)
                if index + 1 < argv.count { options.append(argv[index + 1]) }
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                options.append(token)
                index += 1
                continue
            }
            break
        }
        guard index < argv.count, readOnlySubcommands.contains(argv[index]) else { return nil }

        // Empty means unset, whatever the repository, the user's global config
        // or an includeIf rule said. Ours go first; a caller that hardened the
        // same way already just says it twice.
        var hardened = [argv[0], "-c", "core.fsmonitor=", "-c", "diff.external="]
        hardened.append(contentsOf: options)
        hardened.append(argv[index])
        if argv[index] == "diff" {
            // `--no-ext-diff` is the half `diff.external=` cannot cover: a
            // repository may define any number of named drivers, so they can
            // only be turned off as a class. Both are accepted in --no-index
            // mode. Nothing is lost by refusing, since the panel wants git's
            // own diff text and an external differ exists to replace it.
            hardened.append(contentsOf: ["--no-ext-diff", "--no-textconv"])
        }
        hardened.append(contentsOf: argv[(index + 1)...])
        return hardened
    }

    /// Reads only. `fetch`, `checkout`, `stash`, `gc` and the rest are absent
    /// rather than filtered out, so a subcommand added later has to be added
    /// here on purpose.
    private static let readOnlySubcommands: Set<String> = [
        "rev-parse", "status", "diff", "ls-files", "show", "log", "cat-file",
        "symbolic-ref", "for-each-ref", "describe", "blame", "rev-list",
        "ls-tree", "name-rev", "check-ignore", "diff-tree", "diff-index",
    ]

    // ------------------------------------------------------------------- pipe

    /// True when the whole command reached the far end. One write and one
    /// flush, so a partial line never sits in the pipe waiting for a marker
    /// that will not be printed until the rest of it arrives.
    private func write(_ text: String) -> Bool {
        guard let fd = inputPipe?.fileHandleForWriting.fileDescriptor else { return false }

        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            // EPIPE: ssh is gone. Its stderr says why, if it managed to.
            fail(explain(errors?.drained(within: Self.stderrGrace) ?? ""))
            return false
        }
        return true
    }

    /// Turns ssh's own complaint into something worth putting in a panel. The
    /// raw text is kept when it is already clear, because ssh is usually better
    /// at saying what went wrong than a guess would be.
    private func explain(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "The connection closed before it could be used"
        }

        let lowered = text.lowercased()
        if lowered.contains("permission denied") || lowered.contains("publickey") {
            return "This host wants a password. Zharp only connects with a key, "
                + "so it never has to prompt you."
        }
        if lowered.contains("host key verification failed") {
            return "The host key is not trusted yet. Connect once in the terminal to accept it."
        }

        // One line is a message; a stack of them is a log.
        if let newline = text.firstIndex(of: "\n") {
            return String(text[text.startIndex..<newline])
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private func fail(_ reason: String) {
        state.locked {
            dead = true
            if openProblem == nil { openProblem = reason }
        }
    }

    // ------------------------------------------------------------- closing it

    /// Closes the connection. Safe to call twice, and from any thread.
    public func dispose() {
        let process: Process? = state.locked {
            dead = true
            if disposed { return nil }
            disposed = true
            return self.process
        }
        guard let process else { return }

        // Closing stdin is the polite half and almost always the whole of it:
        // the remote `sh` reads EOF, exits, and ssh follows it. The kill is a
        // backstop for a far end that ignores EOF, scheduled rather than waited
        // for so that quitting the app does not park a thread per host.
        try? inputPipe?.fileHandleForWriting.close()
        // NOT on errorQueue. That queue is serial and the stderr pump is sitting
        // on it in a blocking read that only returns when ssh exits, so a kill
        // scheduled there would be queued behind the very exit it exists to
        // force, and a far end that ignores EOF would never be killed at all.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            guard process.isRunning else { return }
            Self.terminate(process)
        }
    }

    deinit {
        dispose()
    }

    /// SIGKILL rather than a polite SIGTERM: this only runs once the connection
    /// has overrun its budget or is being torn down, and in both cases a signal
    /// the process might choose to handle is no use.
    private static func terminate(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        // Only when the child genuinely leads its own group, so this can never
        // reach back into Zharp itself. When it does, everything ssh started
        // goes with it.
        let group = getpgid(pid)
        if group == pid && group != getpgrp() {
            Darwin.kill(-group, SIGKILL)
        }
        Darwin.kill(pid, SIGKILL)
    }
}

// ------------------------------------------------------------------ registry

/// One channel per distinct ssh target, shared by every tab on it and closed
/// once nothing has asked it anything for a while.
public enum SshGitChannels {

    /// Whether Zharp may open connections of its own at all. Off means a
    /// session over ssh shows what it knows and nothing more, which is a
    /// legitimate thing to want on a host where every login is audited or where
    /// a second session would trip an alert. Turning it off closes what is open.
    public static var enabled: Bool {
        get { lock.locked { switchedOn } }
        set {
            let changed = lock.locked { () -> Bool in
                let was = switchedOn
                switchedOn = newValue
                return was != newValue
            }
            // Turning it off means now, not in five minutes when the last of
            // them idles out. The reasons for switching it off (an audited
            // host, an alert on every login) are all about the connection
            // existing at all, so this does not wait for a caller to remember.
            if changed && !newValue { closeAll() }
        }
    }

    /// A connection nothing has asked anything for this long is closed. An idle
    /// ssh session on someone's server is not free: it holds a process, and it
    /// shows up in `w` looking like a person.
    private static let idleLimit: TimeInterval = 5 * 60

    /// How long a failure is remembered. Long enough that a host wanting a
    /// password is not re-dialled on every poll, short enough that accepting
    /// the host key in the terminal, which is what the panel just told the user
    /// to do, starts working without restarting Zharp.
    private static let failureLimit: TimeInterval = 30

    private static let lock = NSLock()
    private static var switchedOn = true
    private static var open: [String: Entry] = [:]
    private static var sweepScheduled = false

    private struct Entry {
        /// The connect is held as a task rather than a channel so two tabs
        /// reaching the same host at the same moment wait on one handshake
        /// instead of opening two connections.
        let opening: Task<SshGitChannel, Never>
        let openedAt: Date
        var lastUsed: Date
    }

    /// The channel for a host, opening one if there is not one already. Nil
    /// when the feature is off, or when this is a host Zharp only heard about
    /// and therefore must never dial.
    public static func channel(for host: RemoteHost) async -> SshGitChannel? {
        guard host.canConnect else { return nil }

        // The lock is never held across an await, and never touched from inside
        // this function: it lives in `claim` and `drop`, which are ordinary
        // synchronous code. A lock taken in an async function is a lock a
        // suspension can strand.
        while true {
            guard let entry = claim(host) else { return nil }

            let existing = await entry.opening.value
            if existing.isUsable { return existing }

            // A failed channel is remembered so a host that wants a password is
            // not re-dialled on every poll. It is remembered against the moment
            // it was opened rather than the moment it was last asked: a panel
            // polling every six seconds would refresh lastUsed forever, which
            // is how a connection that could work again never gets the chance.
            if Date().timeIntervalSince(entry.openedAt) < failureLimit { return existing }

            // Past the retry window. Drop it and go round again, which opens a
            // fresh one unless another caller has already put one in its place.
            if drop(host, openedAt: entry.openedAt) {
                existing.dispose()
            }
        }
    }

    /// The entry for a host, opening one if there is not one already. Nil when
    /// the feature is off. Synchronous, so the lock is taken and released
    /// without a suspension point anywhere between.
    private static func claim(_ host: RemoteHost) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard switchedOn else { return nil }

        let now = Date()
        sweepLocked(now)

        if var entry = open[host.key] {
            entry.lastUsed = now
            open[host.key] = entry
            return entry
        }

        let entry = Entry(opening: Task { await SshGitChannel.connect(to: host) },
                          openedAt: now, lastUsed: now)
        open[host.key] = entry
        scheduleSweepLocked()
        return entry
    }

    /// Forgets a channel, but only the exact one the caller was holding: two
    /// tabs can reach the end of the retry window together, and the second must
    /// not throw away the connection the first has just opened.
    private static func drop(_ host: RemoteHost, openedAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = open[host.key], entry.openedAt == openedAt else { return false }
        open.removeValue(forKey: host.key)
        return true
    }

    /// Closes what has gone idle. Called on its own timer so the five minutes
    /// is a promise rather than something that happens to be true while a panel
    /// is still asking: a user who leaves a remote tab open and walks away
    /// should not leave a session behind on someone's server.
    public static func sweep() {
        lock.lock()
        sweepLocked(Date())
        lock.unlock()
    }

    private static func sweepLocked(_ now: Date) {
        let cutoff = now.addingTimeInterval(-idleLimit)
        let stale = open.filter { $0.value.lastUsed < cutoff }
        for (key, entry) in stale {
            open.removeValue(forKey: key)
            // Off the lock, and off this thread: closing waits on nothing, but
            // the handshake it may still be inside of does.
            Task {
                let channel = await entry.opening.value
                channel.dispose()
            }
        }
    }

    /// One shot rather than a repeating timer, re-armed only while something is
    /// open, so an app with no remote tabs is not waking the CPU every minute
    /// to look at an empty dictionary.
    private static func scheduleSweepLocked() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleLimit + 5) {
            lock.lock()
            sweepScheduled = false
            sweepLocked(Date())
            if !open.isEmpty { scheduleSweepLocked() }
            lock.unlock()
        }
    }

    /// Closes everything, on shutdown or when the user turns this off.
    public static func closeAll() {
        lock.lock()
        let entries = Array(open.values)
        open.removeAll()
        lock.unlock()
        for entry in entries {
            Task {
                let channel = await entry.opening.value
                channel.dispose()
            }
        }
    }
}

// -------------------------------------------------------------- reading lines

/// Lines from a file descriptor, with a deadline.
///
/// FileHandle cannot be read with a timeout, and the whole point of a budget
/// here is that a remote which has stopped answering releases the panel rather
/// than holding it. poll(2) gives the deadline; the buffering is here because
/// what arrives is a byte stream that happens to be newline framed, and a
/// single read can land halfway through a line or hold three of them.
private final class LineReader {
    enum Outcome {
        case line(String)
        /// The far end closed its side. Nothing more will arrive, ever.
        case closed
        case timedOut
    }

    private let fd: Int32
    private var pending: [UInt8] = []
    private var atEnd = false

    /// A base64'd `git diff` of a large file is legitimately megabytes on one
    /// line, so this is not a plausible answer, it is a far end that has
    /// stopped emitting newlines. Big enough never to be hit by an answer,
    /// small enough not to be a way to exhaust memory.
    private static let lineLimit = 64 * 1024 * 1024

    init(_ fd: Int32) {
        self.fd = fd
        // Non-blocking so poll decides how long a read waits, not the kernel.
        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
    }

    func next(by deadline: Date) -> Outcome {
        while true {
            if let line = takeLine() { return .line(line) }
            if atEnd {
                // Whatever was left without a terminator still counts as a
                // line, the way a line reader anywhere else would treat it.
                if !pending.isEmpty {
                    let last = String(decoding: pending, as: UTF8.self)
                    pending.removeAll()
                    return .line(trimCarriageReturn(last))
                }
                return .closed
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // Capped so the deadline is still checked on a connection that goes
            // quiet without closing.
            let milliseconds = Int32(min(remaining, 1) * 1000) + 1
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                atEnd = true
                continue
            }
            if ready == 0 { continue }

            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                pending.append(contentsOf: chunk[0..<count])
                if pending.count > Self.lineLimit {
                    pending.removeAll()
                    atEnd = true
                }
            } else if count == 0 {
                atEnd = true
            } else if errno != EINTR && errno != EAGAIN {
                atEnd = true
            }
        }
    }

    private func takeLine() -> String? {
        guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
        let line = String(decoding: pending[0..<newline], as: UTF8.self)
        pending.removeFirst(newline + 1)
        return trimCarriageReturn(line)
    }

    /// There is no pty on this connection, so nothing should be translating
    /// line endings. A remote that prints CRLF anyway is not worth failing a
    /// marker comparison over.
    private func trimCarriageReturn(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}

/// ssh's own stderr, drained on a thread of its own and capped.
///
/// Separate from the answer stream because it is the only place the reason for
/// a failure appears, and because a far end that chats on stderr must not be
/// able to fill memory or block ssh by filling a pipe nobody empties.
private final class StderrPump: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private let finished = DispatchSemaphore(value: 0)

    /// Four thousand characters is several screens of ssh being unhappy. Past
    /// that it is a log, and only the first line is ever shown.
    private static let limit = 4000

    init(_ fd: Int32, on queue: DispatchQueue) {
        queue.async { [self] in
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = chunk.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    let piece = String(decoding: chunk[0..<count], as: UTF8.self)
                    lock.lock()
                    if text.count < Self.limit { text += piece }
                    lock.unlock()
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            finished.signal()
        }
    }

    /// What ssh said, waiting a moment for it to finish saying it. stdout and
    /// stderr close at almost the same instant and in no fixed order, so
    /// reading stderr the moment stdout ends often reads it empty.
    func drained(within seconds: TimeInterval) -> String {
        _ = finished.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
