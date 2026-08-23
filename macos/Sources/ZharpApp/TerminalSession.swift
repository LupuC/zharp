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

    /// Shell-reported current directory; falls back to the start directory.
    private(set) var workingDirectory: String?
    var isStarted: Bool { pty != nil }

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
    var workingDirectoryChanged: ((String) -> Void)?
    var commandExecuted: ((String) -> Void)?
    var exited: ((Int32) -> Void)?
    var bell: (() -> Void)?

    init(arguments: [String], workingDirectory: String?, initialTitle: String,
         scrollbackLines: Int = 10000) {
        self.arguments = arguments
        self.startDirectory = workingDirectory
        self.workingDirectory = workingDirectory
        self.title = initialTitle
        emulator = TerminalEmulator(cols: 120, rows: 30, maxScrollback: max(100, scrollbackLines))

        emulator.titleChanged = { [weak self] title in
            guard let self else { return }
            if !title.trimmingCharacters(in: .whitespaces).isEmpty {
                self.title = title
            }
            self.titleChanged?(self.title)
        }
        emulator.workingDirectoryChanged = { [weak self] cwd in
            self?.workingDirectory = cwd
            self?.workingDirectoryChanged?(cwd)
        }
        emulator.responseRequested = { [weak self] sequence in
            self?.writeRaw(sequence)
        }
        emulator.commandExecuted = { [weak self] command in
            if ProcessInfo.processInfo.environment["ZHARP_DEBUG_HISTORY"] == "1" {
                App.log("cmd[mark] '\(command)'")
            }
            self?.commandExecuted?(command)
        }
        emulator.bellRang = { [weak self] in
            self?.bell?()
        }
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
        // screen (clear, cls) before it arrives.
        if commandExecuted != nil, text.contains("\r") {
            emulator.syncRoot.lock()
            let pending = emulator.peekPendingCommand()
            emulator.syncRoot.unlock()
            if ProcessInfo.processInfo.environment["ZHARP_DEBUG_HISTORY"] == "1" {
                App.log("cmd[enter] pending='\(pending ?? "<nil>")'")
            }
            if let pending { commandExecuted?(pending) }
        }
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
