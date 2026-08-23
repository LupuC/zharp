import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Hosts a child process attached to a Unix pseudoterminal - the macOS
/// counterpart of the Windows build's ConPTY host. Write VT input to `input`,
/// read VT output from `output`.
public final class PseudoTerminal {
    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var disposed = false
    private let lock = NSLock()
    private var reapSource: DispatchSourceProcess?

    public private(set) var input: FileHandle!
    public private(set) var output: FileHandle!
    public var processId: Int32 { childPid }

    /// Raised (on a background queue) when the child process exits.
    public var exited: ((Int32) -> Void)?

    private init() {}

    /// Starts `arguments` under a new pty.
    ///
    /// - Parameters:
    ///   - extraEnvironment: overrides applied on top of the inherited
    ///     environment. A nil value removes the variable from the child.
    public static func start(arguments: [String],
                             workingDirectory: String?,
                             extraEnvironment: [String: String?]?,
                             cols: Int,
                             rows: Int) throws -> PseudoTerminal {
        precondition(!arguments.isEmpty, "a command is required")
        let pty = PseudoTerminal()

        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: UInt16(max(2, rows)), ws_col: UInt16(max(2, cols)),
                           ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PtyError.openFailed(errno)
        }

        let env = buildEnvironment(extraEnvironment)

        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 0)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 1)
        posix_spawn_file_actions_adddup2(&fileActions, slave, 2)
        posix_spawn_file_actions_addclose(&fileActions, slave)
        posix_spawn_file_actions_addclose(&fileActions, master)
        if let workingDirectory, !workingDirectory.isEmpty {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        // The child leads its own session with the pty as controlling terminal,
        // so job control (Ctrl+C, Ctrl+Z, fg/bg) works exactly as in Terminal.app.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        var pid: pid_t = -1
        let argv: [UnsafeMutablePointer<CChar>?] =
            arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup($0) } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        let status = posix_spawnp(&pid, arguments[0], &fileActions, &attributes, argv, envp)
        close(slave)
        guard status == 0 else {
            close(master)
            throw PtyError.spawnFailed(status)
        }

        // The controlling terminal is set by the child's session leader; make
        // sure our own reads never block the writer.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        pty.masterFd = master
        pty.childPid = pid
        pty.input = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        pty.output = FileHandle(fileDescriptor: master, closeOnDealloc: false)

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                      queue: .global())
        source.setEventHandler { [weak pty] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status & 0x7F
            pty?.exited?(Int32(code))
            source.cancel()
        }
        source.resume()
        pty.reapSource = source

        return pty
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        if disposed || masterFd < 0 { return }
        var size = winsize(ws_row: UInt16(max(2, rows)), ws_col: UInt16(max(2, cols)),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &size)
    }

    public func kill() {
        lock.lock()
        defer { lock.unlock() }
        if childPid > 0 {
            // Signal the whole foreground group, like a real terminal hang-up.
            Darwin.kill(-childPid, SIGHUP)
            Darwin.kill(childPid, SIGKILL)
        }
    }

    public func dispose() {
        lock.lock()
        defer { lock.unlock() }
        if disposed { return }
        disposed = true

        reapSource?.cancel()
        reapSource = nil

        if childPid > 0 {
            Darwin.kill(-childPid, SIGHUP)
            Darwin.kill(childPid, SIGKILL)
            var status: Int32 = 0
            waitpid(childPid, &status, WNOHANG)
            childPid = -1
        }

        // Closing the master disconnects the client and unblocks reads.
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }
    }

    deinit { dispose() }

    private static func buildEnvironment(_ extra: [String: String?]?) -> [String] {
        var env = ProcessInfo.processInfo.environment
        if let extra {
            for (key, value) in extra {
                if let value {
                    env[key] = value
                } else {
                    env.removeValue(forKey: key)
                }
            }
        }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    public enum PtyError: Error {
        case openFailed(Int32)
        case spawnFailed(Int32)
    }
}
