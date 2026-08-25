namespace Zharp.App;

/// <summary>
/// The second way an agent can report its state: it drops a small file, and
/// Zharp picks it up.
///
/// Claude Code hands its hook's escape sequence to the terminal for us, which
/// needs no files and routes itself, because whatever comes out of a pty
/// belongs to that pty's tab. Nothing else does that. Codex has no field for
/// returning a terminal sequence, and a hook process has no controlling
/// terminal of its own to write to - on Windows there is not even a /dev/tty
/// to borrow. So for those agents the report travels through the filesystem.
///
/// Routing is not guessed. Zharp puts a unique key in the environment of every
/// shell it starts, the agent's hook inherits it, and the report carries it
/// back. Two Codex sessions in the same repository still land on their own
/// tabs, which matching on the working directory could never manage.
///
/// Each report is a separate file, written elsewhere and renamed into place.
/// Renames are atomic, so a reader can never see half a report, and there is no
/// read offset to keep in step with a writer.
/// </summary>
public static class AgentSpool
{
    /// <summary>
    /// Where hooks drop their reports.
    ///
    /// ZHARP_SPOOL_DIR redirects it, which is how this gets exercised without
    /// fighting a running Zharp: two watchers on one directory race for every
    /// report, and whichever reads first deletes it. Same idea as
    /// ZHARP_DUMP_PTY.
    /// </summary>
    public static string Directory { get; } =
        Environment.GetEnvironmentVariable("ZHARP_SPOOL_DIR") is { Length: > 0 } custom
            ? custom
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Zharp", "agents");

    /// <summary>A report arrived, with the session key that identifies its tab.</summary>
    public static event Action<string, AgentReport>? Reported;

    private static FileSystemWatcher? _watcher;
    private static readonly object Gate = new();

    /// <summary>Starts watching. Safe to call more than once.</summary>
    public static void Start()
    {
        lock (Gate)
        {
            if (_watcher != null)
                return;

            try
            {
                System.IO.Directory.CreateDirectory(Directory);
                PruneStale();

                _watcher = new FileSystemWatcher(Directory, "*.json")
                {
                    NotifyFilter = NotifyFilters.FileName,
                    IncludeSubdirectories = false,
                };

                // Both, and Renamed is the one that actually fires. A hook
                // writes its report under a name this filter ignores and then
                // renames it into place, so that a half written file can never
                // be read; a rename within one directory is a Renamed event,
                // not a Created one. Created stays for anything that writes
                // the file directly.
                _watcher.Created += (_, e) => Deliver(e.FullPath);
                _watcher.Renamed += (_, e) => Deliver(e.FullPath);

                // A watcher that dies takes every agent's status with it and
                // says nothing, so at least leave a trace.
                _watcher.Error += (_, e) =>
                    App.Log($"agent spool: watcher failed: {e.GetException().Message}");

                _watcher.EnableRaisingEvents = true;

                // Anything already waiting. Done after the watcher is live so
                // nothing can slip through the gap between the two.
                foreach (string path in System.IO.Directory.EnumerateFiles(Directory, "*.json"))
                    Deliver(path);
            }
            catch (Exception ex)
            {
                App.Log($"agent spool: could not start: {ex.Message}");
                _watcher = null;
            }
        }
    }

    /// <summary>
    /// Clears out half written reports abandoned by a hook that died mid write.
    /// Only old ones: a hook running right now owns its temporary file, and a
    /// second Zharp may be running too. Finished reports are not touched here;
    /// those get delivered instead.
    /// </summary>
    private static void PruneStale()
    {
        try
        {
            var cutoff = DateTime.UtcNow - TimeSpan.FromHours(1);
            foreach (string path in System.IO.Directory.EnumerateFiles(Directory, "*.tmp"))
            {
                try
                {
                    if (File.GetLastWriteTimeUtc(path) < cutoff)
                        File.Delete(path);
                }
                catch
                {
                    // In use, or gone already. Either way not ours to worry about.
                }
            }
        }
        catch (Exception ex)
        {
            App.Log($"agent spool: prune failed: {ex.Message}");
        }
    }

    private static void Deliver(string path)
    {
        // Raised on a threadpool thread. Whoever subscribes marshals.
        try
        {
            string? text = ReadAndRemove(path);
            if (text == null)
                return;

            if (AgentReport.Parse(text) is not { } report)
                return;
            if (report.Session is not { Length: > 0 } key)
                return; // nothing to route it to

            Reported?.Invoke(key, report);
        }
        catch (Exception ex)
        {
            App.Log($"agent spool: {ex.Message}");
        }
    }

    /// <summary>
    /// Reads a report and takes it out of the way.
    ///
    /// The rename should mean the content is already whole, but a watcher can
    /// still beat the filesystem to it, so a couple of quick retries cost
    /// nothing and save a dropped report.
    /// </summary>
    private static string? ReadAndRemove(string path)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                string text = File.ReadAllText(path);
                File.Delete(path);
                return text;
            }
            catch (FileNotFoundException)
            {
                return null; // somebody else got there first
            }
            catch (DirectoryNotFoundException)
            {
                return null;
            }
            catch (IOException)
            {
                Thread.Sleep(15); // still being written
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(15);
            }
        }
        return null;
    }
}
