import Foundation
import ZharpCore

/// Glues a pty-hosted shell process to a `TerminalEmulator`: pumps process
/// output into the emulator and serializes user input back.
final class TerminalSession {
    private let arguments: [String]
    private let startDirectory: String?
    private let writeLock = NSLock()

    private var pty: PseudoTerminal?
    private var readerThread: Thread?
    private var disposed = false

    let emulator: TerminalEmulator
    private(set) var title: String

    /// Identifies this session to anything running inside it.
    ///
    /// Zharp puts it in the shell's environment, so an agent's hook inherits it
    /// and can name the tab it belongs to when it has no other way to say.
    /// That is what lets two agents in the same repository report separately,
    /// which matching on the working directory cannot do.
    let sessionKey = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// Shell-reported current directory; falls back to the start directory.
    /// Always a path on THIS machine: see `location` for where the session
    /// actually is once it has been sent somewhere over ssh.
    private(set) var workingDirectory: String?
    var isStarted: Bool { pty != nil }

    /// Where this session is standing, machine included.
    ///
    /// `workingDirectory` only ever describes this computer, which stops being
    /// true the moment the user types `ssh`. Anything that asks a question
    /// about the directory, rather than only displaying it, has to ask this
    /// instead: on macOS a remote POSIX path is a syntactically perfect local
    /// one, so a path that has lost its machine reads whatever happens to be
    /// there and says nothing about it.
    /// Read under the same lock the writer holds. The pty reader thread sets
    /// this and the main thread reads it on every tab switch and panel refresh,
    /// and a torn read here is a session pointed at the wrong machine.
    var location: SessionLocation? {
        locationLock.lock()
        defer { locationLock.unlock() }
        return storedLocation
    }

    private var storedLocation: SessionLocation?

    /// Raised when the session changes machine or directory. Raised on
    /// whichever thread noticed: the pty reader for anything the shell said,
    /// the main thread for a command typed at the prompt.
    var locationChanged: ((SessionLocation?) -> Void)?

    /// The machine an `ssh` typed at this prompt went to, until a prompt comes
    /// back here. Zharp knows the command because it already reads the prompt
    /// line for history, which is why this works on a plain server that reports
    /// nothing about itself.
    private var remote: RemoteHost?

    /// Where the user is on `remote`, when anything over there has said so.
    /// Empty is a normal state, not a failure: plenty of servers report no
    /// directory at all.
    private var remotePath = ""

    /// The last machine name the far end reported through OSC 7. Kept so a
    /// SECOND, different name can be noticed: see `noteRemoteDirectory`.
    private var remoteName: String?

    /// `remote`, `remotePath`, `remoteName` and `location` are written from the
    /// pty reader thread (anything the shell said) and from the main thread
    /// (Enter at the prompt), so the four move together under this.
    private let locationLock = NSLock()

    /// When true, NO_COLOR is stripped from the child environment.
    var overrideNoColor = true

    /// Additional environment overrides for the child (nil value = remove).
    var extraEnvironment: [String: String?]?

    /// Raised on a background thread after output has been processed.
    ///
    /// Multicast: the renderer subscribes to repaint, and the tab subscribes to
    /// scrape agent status. C# events are multicast by default, so the Windows
    /// build gets this for free - a plain Swift closure property would let the
    /// second subscriber silently replace the first, and the terminal would
    /// stop redrawing entirely.
    private var outputObservers: [() -> Void] = []
    private let observerLock = NSLock()

    func addOutputObserver(_ observer: @escaping () -> Void) {
        observerLock.lock()
        outputObservers.append(observer)
        observerLock.unlock()
    }

    func removeAllOutputObservers() {
        observerLock.lock()
        outputObservers.removeAll()
        observerLock.unlock()
    }

    private func notifyOutputArrived() {
        observerLock.lock()
        let observers = outputObservers
        observerLock.unlock()
        for observer in observers { observer() }
    }
    var titleChanged: ((String) -> Void)?
    var commandExecuted: ((String) -> Void)?
    var exited: ((Int32) -> Void)?
    var bell: (() -> Void)?

    /// An AI agent running in this session reporting its own state. Raised on
    /// the pty thread with the raw JSON body, straight off the wire: whoever
    /// takes it parses it, and treats it as hostile until it has.
    var agentReported: ((String) -> Void)?

    /// The shell is back at a fresh prompt, so whatever was running in the
    /// foreground has exited. Raised on the pty thread.
    var promptReturned: (() -> Void)?

    /// The user sent input to this session. Main thread, since that is where
    /// keystrokes arrive.
    ///
    /// Worth an event because of what it means when an agent is waiting: they
    /// have answered it. No agent emits "that permission was resolved", and
    /// subscribing to every tool call to infer it costs a process per call.
    /// Zharp is the one holding the keyboard, so it already knows.
    var userTyped: (() -> Void)?

    init(arguments: [String], workingDirectory: String?, initialTitle: String,
         scrollbackLines: Int = 10000) {
        self.arguments = arguments
        self.startDirectory = workingDirectory
        self.workingDirectory = workingDirectory
        self.storedLocation = SessionLocation.local(workingDirectory)
        self.title = initialTitle
        emulator = TerminalEmulator(cols: 120, rows: 30, maxScrollback: max(100, scrollbackLines))

        emulator.titleChanged = { [weak self] title in
            guard let self else { return }
            if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                self.title = title
            }
            self.noteTitle(self.title)
            self.titleChanged?(self.title)
        }
        emulator.workingDirectoryChanged = { [weak self] cwd in
            guard let self else { return }

            // Read straight off the emulator rather than from the argument:
            // both halves of (machine, path) are settled before this fires,
            // and the pair is what says where the session is.
            if let host = self.emulator.workingDirectoryHost {
                self.noteRemoteDirectory(host, cwd)
                return
            }

            // A local report. It is also how a session comes home as far as the
            // directory goes, but it is deliberately NOT how it stops being
            // remote: see `leaveRemote`.
            //
            // There is no directory-only event to raise here on purpose. One
            // used to exist and everything watched it, which is precisely why
            // typing `ssh` changed nothing anyone could see: a path with no
            // machine attached is not an answer to "where is this session".
            self.workingDirectory = cwd
            self.updateLocation()
        }
        emulator.responseRequested = { [weak self] sequence in
            self?.writeRaw(sequence)
        }
        emulator.commandExecuted = { [weak self] command in
            if ProcessInfo.processInfo.environment["ZHARP_DEBUG_HISTORY"] == "1" {
                App.log("cmd[mark] '\(command)'")
            }
            // History only. This fires when a prompt mark arrives, and a prompt
            // mark is a byte sequence any program that writes to the terminal
            // can produce: the output of `cat`, of `curl`, or of a shell on
            // another machine. Text captured this way is therefore output, not
            // input, and output must never choose a machine to connect to.
            // `noteCommand` is called from `send` instead, where a person
            // pressing Enter is what caused it.
            self?.commandExecuted?(command)
        }
        emulator.bellRang = { [weak self] in
            self?.bell?()
        }
        emulator.agentReported = { [weak self] payload in
            self?.agentReported?(payload)
        }
        emulator.promptReturned = { [weak self] in
            // The LOCAL shell has drawn a new prompt, so whatever it was
            // running, ssh included, has exited. This is the only signal that
            // cannot be missed: a remote shell need not say goodbye, and the
            // connection may have ended by the laptop lid closing.
            self?.leaveRemote()
            self?.promptReturned?()
        }
    }

    // ---------------------------------------------------------------- location

    /// Notices an `ssh` being run, from the command line the user typed.
    ///
    /// This is the only one of the three signals that needs nothing at all from
    /// the far end, and the only one Zharp will ever connect on: it was read at
    /// a local prompt, before anything was sent. `SshTarget.parse` is the sole
    /// producer of the argument list a second connection is built from, so a
    /// name that arrived over the wire cannot get here.
    ///
    /// Called from `send` alone, on Enter. Deliberately NOT from the
    /// emulator's own command-finished callback: that one fires on a prompt
    /// mark, and a prompt mark is a byte sequence, so a program printing
    /// OSC 133 could hand this whatever command line it liked and choose where
    /// Zharp connects. Enter is the one signal a person has to supply.
    private func noteCommand(_ command: String) {
        guard let host = SshTarget.parse(command) else { return }
        locationLock.lock()
        remote = host
        remotePath = ""
        remoteName = nil
        locationLock.unlock()
        updateLocation()
    }

    /// Takes an OSC 7 report from a shell that says it is on another machine.
    ///
    /// The name is only ever used to SAY where the session is. `RemoteHost` has
    /// no way to turn one into a connection: only the `.watched` case carries
    /// an argument list, and only `SshTarget.parse` produces one.
    ///
    /// A name that is not a machine name drops the whole report rather than
    /// falling back to treating the path as local. That fallback is the
    /// original bug, and it is worse here than on Windows: /home/me/app off a
    /// Linux box is a perfectly ordinary path on a Mac, so the panel would read
    /// whatever is at that path locally and present it as the server's.
    private func noteRemoteDirectory(_ host: String, _ path: String) {
        guard let reported = RemoteHost.reported(host) else { return }

        locationLock.lock()
        if let seen = remoteName, seen.caseInsensitiveCompare(reported.label) != .orderedSame {
            // A SECOND, different name on the same connection means the machine
            // underneath changed without Zharp watching an ssh: an `ssh` typed
            // at the remote prompt, which the prompt marks over here cannot
            // see. Whatever invocation was being held reaches the first hop,
            // not this one, so reading git through it would show a different
            // computer's repository under this computer's name, which is the
            // failure this whole feature exists to end. Demote to the name
            // alone, which can be shown and cannot be dialled.
            //
            // Not re-promoted when the user exits back to the first hop. The
            // cost is a panel that names the machine and stops until they log
            // in again; the alternative is guessing, and guessing here means
            // logging in to the wrong server.
            remote = reported
        } else if remote == nil {
            remote = reported
        }
        // Otherwise the machine Zharp watched us reach is the machine that just
        // introduced itself, under whichever spelling. The watched host is kept
        // because it is the one carrying an invocation, and because its label is
        // what the user typed and therefore what they will recognise.
        remoteName = reported.label
        remotePath = path
        locationLock.unlock()
        updateLocation()
    }

    /// Takes the directory out of a remote shell's window title.
    ///
    /// Only consulted while the session is already known to be elsewhere, and
    /// only for the path. A title is a string any program can set to anything,
    /// so it is a hint about a machine already established, never the thing
    /// that establishes one, and never a reason to change machine.
    private func noteTitle(_ title: String) {
        locationLock.lock()
        let elsewhere = remote != nil
        locationLock.unlock()
        guard elsewhere, let parsed = PromptTitle.parse(title) else { return }

        locationLock.lock()
        let moved = parsed.path != remotePath
        if moved { remotePath = parsed.path }
        locationLock.unlock()
        if moved { updateLocation() }
    }

    /// The session is on this machine again.
    private func leaveRemote() {
        locationLock.lock()
        let wasRemote = remote != nil
        remote = nil
        remotePath = ""
        remoteName = nil
        locationLock.unlock()
        if wasRemote { updateLocation() }
    }

    private func updateLocation() {
        locationLock.lock()
        let next = remote.map { SessionLocation.on($0, path: remotePath) }
            ?? SessionLocation.local(workingDirectory)
        let moved = next != storedLocation
        if moved { storedLocation = next }
        locationLock.unlock()
        if moved { locationChanged?(next) }
    }

    func ensureStarted(cols: Int, rows: Int) {
        if pty != nil || disposed { return }

        emulator.resize(cols: cols, rows: rows)

        var env: [String: String?] = [
            "TERM": "xterm-256color",
            "TERM_PROGRAM": "Zharp",
            "TERM_PROGRAM_VERSION": App.version,
            "COLORTERM": "truecolor",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",

            // The version of the agent-report protocol this build understands.
            // Agent hooks check for it and stay silent when it is absent, so the
            // same hook can be installed once and cost nothing in any other
            // terminal. Bump it only for a change old Zharps cannot read.
            "ZHARP_AGENT_PROTOCOL": "1",

            // Which tab this shell is. Only agents that report through the
            // spool need it, but every session gets one: which agent somebody
            // runs is not knowable when the shell starts.
            "ZHARP_SESSION": sessionKey,
            "ZHARP_SPOOL": AgentSpool.directory.path,

            // Strip session markers Zharp may have inherited from its own parent
            // (e.g. when launched from inside a Claude Code session). Leaking them
            // makes a nested `claude` think it's a child session and disable
            // transcript saving. Every tab gets a clean slate, like a fresh console.
            "CLAUDE_CODE_CHILD_SESSION": nil,
            "CLAUDE_CODE_SESSION_ID": nil,
            "CLAUDECODE": nil,
            "CLAUDE_CODE_ENTRYPOINT": nil,
        ]
        if let extraEnvironment {
            for (key, value) in extraEnvironment { env[key] = value }
        }
        if overrideNoColor {
            env["NO_COLOR"] = .some(nil) // remove from child environment
        }

        do {
            let pty = try PseudoTerminal.start(arguments: arguments,
                                               workingDirectory: startDirectory,
                                               extraEnvironment: env,
                                               cols: cols, rows: rows)
            pty.exited = { [weak self] code in
                guard let self, !self.disposed else { return }
                self.exited?(code)
            }
            self.pty = pty
        } catch {
            App.log("Starting \(arguments.first ?? "shell") failed: \(error)")
            emulator.feed(text: "\r\n\u{1b}[31mZharp could not start \(arguments.first ?? "the shell").\u{1b}[0m\r\n")
            notifyOutputArrived()
            return
        }

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "Zharp PTY reader"
        thread.stackSize = 512 * 1024
        thread.start()
        readerThread = thread
    }

    private func readLoop() {
        guard let pty else { return }
        let fd = pty.output.fileDescriptor
        let capacity = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        while !disposed {
            let count = read(fd, buffer, capacity)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                break
            }
            emulator.feed(UnsafeBufferPointer(start: buffer, count: count))
            notifyOutputArrived()
        }
    }

    func resize(cols: Int, rows: Int) {
        emulator.resize(cols: cols, rows: rows)
        pty?.resize(cols: cols, rows: rows)
    }

    /// Sends user-typed text to the shell.
    func send(_ text: String) {
        // Enter executes whatever is typed at the prompt: capture it NOW.
        // Waiting for the next prompt mark loses commands that clear the
        // screen (clear, cls) before it arrives, and for `ssh` it would mean
        // learning where the session went only once it had come back.
        if commandExecuted != nil || locationChanged != nil, text.contains("\r") {
            emulator.syncRoot.lock()
            let pending = emulator.peekPendingCommand()
            emulator.syncRoot.unlock()
            if ProcessInfo.processInfo.environment["ZHARP_DEBUG_HISTORY"] == "1" {
                App.log("cmd[enter] pending='\(pending ?? "<nil>")'")
            }
            if let pending {
                noteCommand(pending)
                commandExecuted?(pending)
            }
        }
        userTyped?()
        writeRaw(text)
    }

    /// Sends pasted text, honoring bracketed paste mode.
    func paste(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        emulator.syncRoot.lock()
        let bracketed = emulator.bracketedPaste
        emulator.syncRoot.unlock()

        // Pasting an answer counts as answering. Only `send` raised this at
        // first, which left a tab still badged after the user had pasted the
        // path or the branch name the agent was asking for.
        userTyped?()
        writeRaw(bracketed ? "\u{1b}[200~" + normalized + "\u{1b}[201~" : normalized)
    }

    func notifyFocus(_ focused: Bool) {
        emulator.syncRoot.lock()
        let wanted = emulator.focusEvents
        emulator.syncRoot.unlock()
        if wanted {
            writeRaw(focused ? "\u{1b}[I" : "\u{1b}[O")
        }
    }

    private func writeRaw(_ text: String) {
        guard let pty, !disposed else { return }
        let bytes = Array(text.utf8)
        writeLock.lock()
        defer { writeLock.unlock() }
        bytes.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let written = write(pty.input.fileDescriptor,
                                    buf.baseAddress! + offset, buf.count - offset)
                if written <= 0 {
                    if written < 0 && errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    func dispose() {
        if disposed { return }
        disposed = true
        removeAllOutputObservers()
        pty?.dispose()
        pty = nil
    }
}
