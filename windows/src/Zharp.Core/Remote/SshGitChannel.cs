using System.Diagnostics;
using System.Text;

namespace Zharp.Core.Remote;

/// <summary>
/// A second, quiet ssh connection to a machine the user is already on, used to
/// read git there.
///
/// It is a long-lived `ssh host sh` with commands written into its stdin,
/// rather than one `ssh host git ...` per question, because the panel asks
/// several questions every two seconds and an ssh handshake costs a few
/// hundred milliseconds. One connection per host turns that into one
/// round trip per question. OpenSSH's own answer to this is ControlMaster,
/// which the Windows build does not implement, so the multiplexing is done
/// here instead.
///
/// It can never prompt. BatchMode is forced on, ahead of any option the user
/// passed, so a host needing a password or a hardware token fails immediately
/// and says so, rather than blocking on a prompt drawn in a window that has
/// nowhere to show it. Everything it runs is read-only.
/// </summary>
public sealed class SshGitChannel : IDisposable
{
    private readonly Process _process;
    private readonly SemaphoreSlim _turn = new(1, 1);
    private readonly string _marker;
    private readonly StringBuilder _stderr = new();
    private volatile bool _dead;

    /// <summary>The far end's home directory, so a ~ in a path can be expanded
    /// before it is sent. git treats ~ as an ordinary directory name.</summary>
    public string? Home { get; private set; }

    /// <summary>Why this host cannot be read, in words worth showing.</summary>
    public string? Problem { get; private set; }

    public bool IsUsable => !_dead && Problem == null;

    private SshGitChannel(Process process, string marker)
    {
        _process = process;
        _marker = marker;
    }

    /// <summary>Long enough for a busy remote to answer a cold `git status`,
    /// short enough that a wedged connection releases the panel.</summary>
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Which ssh to run. The one on PATH unless ZHARP_SSH names another, which
    /// covers a machine where the usable ssh is Git's rather than Windows' own,
    /// and lets the tests point the whole transport at a local shell.
    /// </summary>
    private static string SshProgram =>
        Environment.GetEnvironmentVariable("ZHARP_SSH") is { Length: > 0 } custom ? custom : "ssh";

    /// <summary>Connect, authenticate and agree that the far end can do the
    /// two things this needs: run a shell, and base64 its output.</summary>
    public static async Task<SshGitChannel> ConnectAsync(RemoteHost host, CancellationToken ct)
    {
        string marker = "ZHARP-END-" + Guid.NewGuid().ToString("N")[..8];

        var psi = new ProcessStartInfo(SshProgram)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
        };

        // Ours first: OpenSSH keeps the first value it is given for an option,
        // so these win over anything the user's own command or config sets.
        // Never prompting is not a preference, it is the only safe behaviour
        // for a connection the user did not ask for and cannot see.
        psi.ArgumentList.Add("-T");
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("BatchMode=yes");
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("ConnectTimeout=10");
        psi.ArgumentList.Add("-o"); psi.ArgumentList.Add("LogLevel=ERROR");
        foreach (var arg in host.Args)
            psi.ArgumentList.Add(arg);
        psi.ArgumentList.Add("sh");

        Process? process;
        try
        {
            process = Process.Start(psi);
        }
        catch (Exception ex)
        {
            return Failed(ex.Message);
        }

        if (process == null)
            return Failed("ssh did not start");

        var channel = new SshGitChannel(process, marker);
        channel.PumpStandardError();

        try
        {
            await channel.HandshakeAsync(ct);
        }
        catch (Exception ex)
        {
            channel.Problem = channel.Explain(ex.Message);
            channel.Dispose();
        }

        return channel;
    }

    private static SshGitChannel Failed(string message)
    {
        // A dead process is still a channel: it carries why, which is the only
        // thing worth saying about this host until the user changes something.
        var placeholder = new Process();
        var channel = new SshGitChannel(placeholder, "") { _dead = true };
        channel.Problem = message.Contains("cannot find", StringComparison.OrdinalIgnoreCase)
            ? "ssh is not installed on this machine"
            : message;
        return channel;
    }

    private async Task HandshakeAsync(CancellationToken ct)
    {
        // $HOME so ~ can be expanded here, and a base64 check because the whole
        // transport depends on it: it is what keeps a filename containing a
        // newline from being read as the end of the answer.
        await WriteAsync(
            "printf 'ZHARP-HOME %s\\n' \"$HOME\"; " +
            "if command -v base64 >/dev/null 2>&1; then printf 'ZHARP-OK\\n'; " +
            "else printf 'ZHARP-NO-BASE64\\n'; fi\n", ct);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));

        while (true)
        {
            string? line = await _process.StandardOutput.ReadLineAsync(timeout.Token);
            if (line == null)
            {
                _dead = true;
                Problem = Explain(_stderr.ToString());
                return;
            }

            if (line.StartsWith("ZHARP-HOME ", StringComparison.Ordinal))
                Home = line["ZHARP-HOME ".Length..].Trim();
            else if (line.StartsWith("ZHARP-NO-BASE64", StringComparison.Ordinal))
            {
                Problem = "The remote shell has no base64, so its output cannot be read safely";
                _dead = true;
                return;
            }
            else if (line.StartsWith("ZHARP-OK", StringComparison.Ordinal))
                return;
        }
    }

    /// <summary>
    /// Turns ssh's own complaint into something worth putting in a panel. The
    /// raw text is kept when it is already clear, because ssh is usually
    /// better at saying what went wrong than a guess would be.
    /// </summary>
    private string Explain(string stderr)
    {
        string text = stderr.Trim();
        if (text.Length == 0)
            return "The connection closed before it could be used";

        if (text.Contains("Permission denied", StringComparison.OrdinalIgnoreCase)
            || text.Contains("publickey", StringComparison.OrdinalIgnoreCase))
            return "This host wants a password. Zharp only connects with a key, so it never has to prompt you.";

        if (text.Contains("Host key verification failed", StringComparison.OrdinalIgnoreCase))
            return "The host key is not trusted yet. Connect once in the terminal to accept it.";

        // One line is a message; a stack of them is a log.
        int newline = text.IndexOf('\n');
        return newline > 0 ? text[..newline].Trim() : text;
    }

    private void PumpStandardError()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                while (await _process.StandardError.ReadLineAsync() is { } line)
                {
                    lock (_stderr)
                    {
                        if (_stderr.Length < 4000)
                            _stderr.AppendLine(line);
                    }
                }
            }
            catch
            {
                // The connection went away; the read side reports that.
            }
        });
    }

    /// <summary>
    /// Runs one read-only command in a directory on the far end and returns
    /// what it wrote to stdout.
    ///
    /// Empty means it produced nothing, whether that is because the directory
    /// is not a repository, the file is not there, or git failed. Every caller
    /// here treats those the same way, so the exit status is not worth the
    /// temporary file it would take to carry back through the pipeline.
    /// </summary>
    public async Task<string> RunAsync(
        string directory, IReadOnlyList<string> argv, CancellationToken ct)
    {
        if (!IsUsable || argv.Count == 0)
            return "";

        var command = new StringBuilder();
        command.Append("{ cd ").Append(ShellWords.Quote(directory)).Append(" 2>/dev/null && ");
        for (int i = 0; i < argv.Count; i++)
        {
            if (i > 0)
                command.Append(' ');
            command.Append(ShellWords.Quote(argv[i]));
        }
        // base64 keeps arbitrary bytes, including the newlines inside a -z
        // record, from being mistaken for the frame that ends the answer.
        command.Append(" 2>/dev/null | base64 | tr -d '\\n'; }; printf '\\n%s\\n' ")
               .Append(ShellWords.Quote(_marker)).Append('\n');

        await _turn.WaitAsync(ct);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(CallTimeout);

            await WriteAsync(command.ToString(), timeout.Token);

            var payload = new StringBuilder();
            while (true)
            {
                string? line = await _process.StandardOutput.ReadLineAsync(timeout.Token);
                if (line == null)
                {
                    // The far end hung up mid answer. The channel cannot be
                    // trusted to be at a frame boundary any more.
                    _dead = true;
                    Problem = Explain(_stderr.ToString());
                    return "";
                }
                if (line == _marker)
                    break;
                payload.Append(line);
            }

            if (payload.Length == 0)
                return "";

            try
            {
                return Encoding.UTF8.GetString(Convert.FromBase64String(payload.ToString()));
            }
            catch (FormatException)
            {
                return "";
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            // Our own timeout, not the caller's. A half-read frame poisons
            // every later one, so the connection goes rather than the answer.
            _dead = true;
            Problem = "The remote stopped answering";
            Dispose();
            return "";
        }
        finally
        {
            _turn.Release();
        }
    }

    private async Task WriteAsync(string text, CancellationToken ct)
    {
        await _process.StandardInput.WriteAsync(text.AsMemory(), ct);
        await _process.StandardInput.FlushAsync(ct);
    }

    public void Dispose()
    {
        _dead = true;
        try
        {
            if (!_process.HasExited)
            {
                _process.StandardInput.Close();
                if (!_process.WaitForExit(500))
                    _process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Already gone, or never started.
        }
        finally
        {
            _process.Dispose();
        }
    }
}

/// <summary>
/// One channel per distinct ssh target, shared by every tab on it and closed
/// once nothing has asked it anything for a while.
/// </summary>
public static class SshGitChannels
{
    private static readonly Dictionary<string, Entry> Open = new(StringComparer.Ordinal);
    private static readonly SemaphoreSlim Gate = new(1, 1);

    private sealed class Entry
    {
        public required SshGitChannel Channel { get; init; }
        public DateTime LastUsed { get; set; }
    }

    /// <summary>
    /// Whether Zharp may open connections of its own at all. Off means a
    /// session over ssh shows what it knows and nothing more, which is a
    /// legitimate thing to want on a host where every login is audited.
    /// </summary>
    public static bool Enabled { get; set; } = true;

    /// <summary>
    /// A connection that has not been asked anything for this long is closed.
    /// An idle ssh session on someone's server is not free: it holds a
    /// process, and it shows up in `w` looking like a person.
    /// </summary>
    private static readonly TimeSpan IdleLimit = TimeSpan.FromMinutes(5);

    public static async Task<SshGitChannel?> GetAsync(RemoteHost host, CancellationToken ct)
    {
        if (!Enabled)
            return null;

        await Gate.WaitAsync(ct);
        try
        {
            Sweep();

            if (Open.TryGetValue(host.Key, out var existing))
            {
                // A failed connection is remembered too, so a host that wants
                // a password is not re-dialled every two seconds. It clears
                // when the user changes something and the entry ages out.
                if (existing.Channel.IsUsable || existing.LastUsed > DateTime.UtcNow - IdleLimit)
                {
                    existing.LastUsed = DateTime.UtcNow;
                    return existing.Channel;
                }
                existing.Channel.Dispose();
                Open.Remove(host.Key);
            }

            var channel = await SshGitChannel.ConnectAsync(host, ct);
            Open[host.Key] = new Entry { Channel = channel, LastUsed = DateTime.UtcNow };
            return channel;
        }
        finally
        {
            Gate.Release();
        }
    }

    private static void Sweep()
    {
        var cutoff = DateTime.UtcNow - IdleLimit;
        foreach (var key in Open.Where(e => e.Value.LastUsed < cutoff).Select(e => e.Key).ToList())
        {
            Open[key].Channel.Dispose();
            Open.Remove(key);
        }
    }

    /// <summary>Closes everything, on shutdown or when the user turns this off.</summary>
    public static void CloseAll()
    {
        Gate.Wait();
        try
        {
            foreach (var entry in Open.Values)
                entry.Channel.Dispose();
            Open.Clear();
        }
        finally
        {
            Gate.Release();
        }
    }
}
