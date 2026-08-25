using System.Text;
using Zharp.Core.Pty;
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

    /// <summary>Shell-reported current directory; falls back to the start directory.</summary>
    public string? WorkingDirectory { get; private set; }
    public bool IsStarted => _pty != null;

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

    public TerminalSession(string commandLine, string? workingDirectory, string initialTitle,
        int scrollbackLines = 10000)
    {
        _commandLine = commandLine;
        _workingDirectory = workingDirectory;
        WorkingDirectory = workingDirectory;
        Title = initialTitle;
        Emulator = new TerminalEmulator(120, 30, Math.Max(100, scrollbackLines));
        Emulator.TitleChanged += title =>
        {
            Title = string.IsNullOrWhiteSpace(title) ? Title : title;
            TitleChanged?.Invoke(Title);
        };
        Emulator.WorkingDirectoryChanged += cwd =>
        {
            WorkingDirectory = cwd;
            WorkingDirectoryChanged?.Invoke(cwd);
        };
        Emulator.ResponseRequested += WriteRaw;
        Emulator.CommandExecuted += cmd => CommandExecuted?.Invoke(cmd);
        Emulator.BellRang += () => Bell?.Invoke();
        Emulator.AgentReported += payload => AgentReported?.Invoke(payload);
        Emulator.PromptReturned += () => PromptReturned?.Invoke();
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
        try
        {
            while (!_disposed)
            {
                int read = pty.Output.Read(buffer, 0, buffer.Length);
                if (read <= 0)
                    break;
                if (Environment.GetEnvironmentVariable("ZHARP_DUMP_PTY") is { Length: > 0 } dump)
                {
                    try { using var fs = new FileStream(dump, FileMode.Append); fs.Write(buffer, 0, read); }
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
        if (CommandExecuted != null && text.IndexOf('\r') >= 0)
        {
            string? pending = null;
            lock (Emulator.SyncRoot)
                pending = Emulator.PeekPendingCommand();
            if (pending != null)
                CommandExecuted(pending);
        }
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
