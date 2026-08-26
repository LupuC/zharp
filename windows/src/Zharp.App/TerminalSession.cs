using System.Text;
using Zharp.Core.Pty;
using Zharp.Core.Remote;
using Zharp.Core.Terminal;

namespace Zharp.App;

/// <summary>
/// Glues a ConPTY-hosted shell process to a <see cref="TerminalEmulator"/>:
/// pumps process output into the emulator and serializes user input back.
/// </summary>
public sealed class TerminalSession : IDisposable
{
    private readonly string _commandLine;
    private readonly string? _workingDirectory;
    private readonly object _writeLock = new();

    private ConPty? _pty;
    private Thread? _readerThread;
    private volatile bool _disposed;

    public TerminalEmulator Emulator { get; }
    public string Title { get; private set; }

    /// <summary>
    /// Identifies this session to anything running inside it.
    ///
    /// Zharp puts it in the shell's environment, so an agent's hook inherits it
    /// and can name the tab it belongs to when it has no other way to say.
    /// That is what lets two agents in the same repository report separately,
    /// which matching on the working directory cannot do.
    /// </summary>
    public string SessionKey { get; } = Guid.NewGuid().ToString("N");

    /// <summary>Shell-reported current directory; falls back to the start directory.
    /// Always a path on this machine: see <see cref="Location"/> for where the
    /// session actually is once it has been sent somewhere over ssh.</summary>
    public string? WorkingDirectory { get; private set; }
    public bool IsStarted => _pty != null;

    /// <summary>
    /// Where this session is standing, machine included.
    ///
    /// <see cref="WorkingDirectory"/> only ever describes this computer, which
    /// stops being true the moment the user types `ssh`. Everything that asks
    /// a question about the directory, rather than just displaying it, should
    /// ask this instead.
    /// </summary>
    public SessionLocation? Location { get; private set; }

    /// <summary>Raised when the session changes machine or directory.</summary>
    public event Action<SessionLocation?>? LocationChanged;

    /// <summary>
    /// The machine an `ssh` typed at this prompt went to, until a prompt comes
    /// back here. Zharp knows the command because it already reads the prompt
    /// line for history, which means this works on a plain server that reports
    /// nothing about itself.
    /// </summary>
    private RemoteHost? _remote;

    /// <summary>Where the user is on <see cref="_remote"/>, when anything over
    /// there has said so. Empty is a normal state, not a failure.</summary>
    private string _remotePath = "";

    /// <summary>When true, NO_COLOR is stripped from the child environment.</summary>
    public bool OverrideNoColor { get; set; } = true;

    /// <summary>Additional environment overrides for the child (null value = remove).</summary>
    public IReadOnlyDictionary<string, string?>? ExtraEnvironment { get; set; }

    /// <summary>Raised on a background thread after output has been processed.</summary>
    public event Action? OutputArrived;
    public event Action<string>? TitleChanged;
    public event Action<string>? WorkingDirectoryChanged;
    public event Action<string>? CommandExecuted;
    public event Action<int>? Exited;
    public event Action? Bell;

    /// <summary>An AI agent running in this session reporting its own state.
    /// Raised on the pty thread with the raw JSON body.</summary>
    public event Action<string>? AgentReported;

    /// <summary>The shell is back at a fresh prompt, so whatever was running in
    /// the foreground has exited.</summary>
    public event Action? PromptReturned;

    /// <summary>
    /// The user sent input to this session.
    ///
    /// Worth an event because of what it means when an agent is waiting: they
    /// have answered it. No agent emits "that permission was resolved", and
    /// subscribing to every tool call to infer it costs a process per call.
    /// Zharp is the one holding the keyboard, so it already knows.
    /// </summary>
    public event Action? UserTyped;

    public TerminalSession(string commandLine, string? workingDirectory, string initialTitle,
        int scrollbackLines = 10000)
    {
        _commandLine = commandLine;
        _workingDirectory = workingDirectory;
        WorkingDirectory = workingDirectory;
        Location = SessionLocation.Local(workingDirectory);
        Title = initialTitle;
        Emulator = new TerminalEmulator(120, 30, Math.Max(100, scrollbackLines));
        Emulator.TitleChanged += title =>
        {
            Title = string.IsNullOrWhiteSpace(title) ? Title : title;
            NoteTitle(Title);
            TitleChanged?.Invoke(Title);
        };
        Emulator.WorkingDirectoryChanged += cwd =>
        {
            // OSC 7 from a shell on another machine describes that machine.
            // Only a local report is allowed to move the local directory.
            if (Emulator.WorkingDirectoryHost is { Length: > 0 } host)
            {
                _remote ??= RemoteHost.Reported(host);
                _remotePath = cwd;
                UpdateLocation();
                return;
            }

            WorkingDirectory = cwd;
            UpdateLocation();
            WorkingDirectoryChanged?.Invoke(cwd);
        };
        Emulator.ResponseRequested += WriteRaw;
        // Deliberately does NOT call NoteCommand. This fires on an OSC 133
        // prompt mark and hands over text scraped off the screen, and a prompt
        // mark is a byte sequence anything writing to the pty can emit. A
        // program that prints "ssh evil.example", then prints a prompt mark,
        // would otherwise have its output parsed as a command the user typed,
        // and the host it named would count as one Zharp watched the user
        // reach: the one kind of host Zharp will dial by itself. History is a
        // different question, since a wrong entry there is only ever wrong.
        Emulator.CommandExecuted += cmd => CommandExecuted?.Invoke(cmd);
        Emulator.BellRang += () => Bell?.Invoke();
        Emulator.AgentReported += payload => AgentReported?.Invoke(payload);
        Emulator.PromptReturned += () =>
        {
            // The local shell has drawn a new prompt, so anything it was
            // running, ssh included, has exited. This is the only signal that
            // cannot be missed: a remote shell need not say goodbye, and the
            // user may have closed the connection by pulling a cable.
            LeaveRemote();
            PromptReturned?.Invoke();
        };
    }

    /// <summary>
    /// Notices an `ssh` being run, from the command line the user typed.
    ///
    /// Called from exactly one place, the Enter path in Send, because this is
    /// what decides which machine Zharp will open its own ssh connection to.
    /// Anything reached from terminal output is a host Zharp merely heard
    /// about, and those are for saying where you are, never for deciding where
    /// to connect.
    /// </summary>
    private void NoteCommand(string command)
    {
        if (SshTarget.Parse(command) is not { } host)
            return;
        _remote = host;
        _remotePath = "";
        UpdateLocation();
    }

    /// <summary>
    /// Takes the directory out of a remote shell's window title.
    ///
    /// Only consulted while the session is known to be elsewhere. A title is
    /// something any program can set to anything, so it is a hint about a
    /// machine already established, never the thing that establishes it.
    /// </summary>
    private void NoteTitle(string title)
    {
        if (_remote == null)
            return;

        var (host, path) = PromptTitle.Parse(title);
        if (host == null || path == null || path == _remotePath)
            return;

        _remotePath = path;
        UpdateLocation();
    }

    private void LeaveRemote()
    {
        if (_remote == null)
            return;
        _remote = null;
        _remotePath = "";
        UpdateLocation();
    }

    private void UpdateLocation()
    {
        var next = _remote != null
            ? SessionLocation.On(_remote, _remotePath)
            : SessionLocation.Local(WorkingDirectory);

        if (Equals(next, Location))
            return;
        Location = next;
        LocationChanged?.Invoke(next);
    }

    public void EnsureStarted(int cols, int rows)
    {
        if (_pty != null || _disposed)
            return;

        Emulator.Resize(cols, rows);

        var env = new Dictionary<string, string?>
        {
            ["TERM_PROGRAM"] = "Zharp",
            ["TERM_PROGRAM_VERSION"] = UpdateService.CurrentVersion.ToString(),
            ["COLORTERM"] = "truecolor",

            // The version of the agent-report protocol this build understands.
            // Agent hooks check for it and stay silent when it is absent, so the
            // same hook can be installed once and cost nothing in any other
            // terminal. Bump it only for a change old Zharps cannot read.
            ["ZHARP_AGENT_PROTOCOL"] = "1",

            // Which tab this shell is. Only agents that report through the
            // spool need it, but every session gets one: which agent somebody
            // runs is not knowable when the shell starts.
            ["ZHARP_SESSION"] = SessionKey,
            ["ZHARP_SPOOL"] = AgentSpool.Directory,

            // Strip session markers Zharp may have inherited from its own parent
            // (e.g. when launched from inside a Claude Code session). Leaking them
            // makes a nested `claude` think it's a child session and disable
            // transcript saving. Every tab gets a clean slate, like a fresh console.
            ["CLAUDE_CODE_CHILD_SESSION"] = null,
            ["CLAUDE_CODE_SESSION_ID"] = null,
            ["CLAUDECODE"] = null,
            ["CLAUDE_CODE_ENTRYPOINT"] = null,
        };
        if (ExtraEnvironment != null)
        {
            foreach (var kv in ExtraEnvironment)
                env[kv.Key] = kv.Value;
        }
        if (OverrideNoColor)
            env["NO_COLOR"] = null; // remove from child environment

        _pty = ConPty.Start(_commandLine, _workingDirectory, env, cols, rows);
        _pty.Exited += code =>
        {
            if (!_disposed)
                Exited?.Invoke(code);
        };

        _readerThread = new Thread(ReadLoop)
        {
            IsBackground = true,
            Name = "Zharp PTY reader",
        };
        _readerThread.Start();
    }

    private void ReadLoop()
    {
        var pty = _pty!;
        var buffer = new byte[65536];

        // Opened once, if at all. This used to read the environment and open,
        // append to and close a file on every single read, on the thread every
        // keystroke has to come back through. A program mid animation sends a
        // chunk per letter, so recording a session made the terminal feel
        // exactly as slow as it was.
        FileStream? dump = null;
        if (Environment.GetEnvironmentVariable("ZHARP_DUMP_PTY") is { Length: > 0 } path)
        {
            try { dump = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read); }
            catch { }
        }

        try
        {
            while (!_disposed)
            {
                int read = pty.Output.Read(buffer, 0, buffer.Length);
                if (read <= 0)
                    break;
                if (dump != null)
                {
                    try { dump.Write(buffer, 0, read); dump.Flush(); }
                    catch { }
                }
                Emulator.Feed(buffer.AsSpan(0, read));
                OutputArrived?.Invoke();
            }
        }
        catch (Exception) when (_disposed)
        {
            // Stream closed during teardown.
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        finally
        {
            dump?.Dispose();
        }
    }

    public void Resize(int cols, int rows)
    {
        Emulator.Resize(cols, rows);
        _pty?.Resize(cols, rows);
    }

    /// <summary>Sends user-typed text to the shell.</summary>
    public void Send(string text)
    {
        // Enter executes whatever is typed at the prompt: capture it NOW.
        // Waiting for the next prompt mark loses commands that clear the
        // screen (cls, clear) before it arrives.
        if (text.IndexOf('\r') >= 0)
        {
            string? pending;
            lock (Emulator.SyncRoot)
                pending = Emulator.PeekPendingCommand();
            if (pending != null)
            {
                // Before the subscriber check: this is the moment an `ssh`
                // becomes true, and it has to be noticed whether or not
                // anything happens to be listening for history.
                NoteCommand(pending);
                CommandExecuted?.Invoke(pending);
            }
        }
        UserTyped?.Invoke();
        WriteRaw(text);
    }

    /// <summary>Sends pasted text, honoring bracketed paste mode.</summary>
    public void Paste(string text)
    {
        text = text.Replace("\r\n", "\r").Replace('\n', '\r');
        bool bracketed;
        lock (Emulator.SyncRoot)
            bracketed = Emulator.BracketedPaste;
        WriteRaw(bracketed ? "\x1b[200~" + text + "\x1b[201~" : text);
    }

    public void NotifyFocus(bool focused)
    {
        bool wanted;
        lock (Emulator.SyncRoot)
            wanted = Emulator.FocusEvents;
        if (wanted)
            WriteRaw(focused ? "\x1b[I" : "\x1b[O");
    }

    private void WriteRaw(string text)
    {
        var pty = _pty;
        if (pty == null || _disposed)
            return;
        try
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            lock (_writeLock)
            {
                pty.Input.Write(bytes, 0, bytes.Length);
                pty.Input.Flush();
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _pty?.Dispose();
    }
}
