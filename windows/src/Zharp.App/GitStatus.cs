using System.Diagnostics;
using System.Text;
using Zharp.Core.Remote;

namespace Zharp.App;

/// <summary>How a file differs from HEAD, as git reports it.</summary>
public enum GitChangeKind
{
    Modified,
    Added,
    Deleted,
    Renamed,
    Untracked,
    Conflicted,
}

/// <summary>One changed path in the working tree or the index.</summary>
public sealed class GitFileChange
{
    /// <summary>Repo-relative, forward slashes, exactly as git prints it.</summary>
    public required string Path { get; init; }

    /// <summary>Where the file came from, when <see cref="Kind"/> is Renamed.</summary>
    public string? OldPath { get; init; }

    public required GitChangeKind Kind { get; init; }

    /// <summary>True when the change is staged rather than only in the working tree.</summary>
    public bool Staged { get; init; }

    /// <summary>Lines added, counted from the diff. -1 until the diff is read.</summary>
    public int Added { get; set; } = -1;

    /// <summary>Lines removed. -1 until the diff is read.</summary>
    public int Removed { get; set; } = -1;

    public string DisplayPath => OldPath is null ? Path : $"{OldPath} → {Path}";
}

/// <summary>
/// A thin, read-only wrapper over the `git` executable.
///
/// It shells out rather than linking a git library on purpose. Zharp is a
/// terminal: git is already on the user's PATH, already configured with their
/// credentials, their includeIf rules, their core.autocrlf and their
/// safe.directory list. A bundled implementation would answer differently from
/// the git sitting one pane away, and being subtly out of step with the shell
/// in the same window is worse than being a few milliseconds slower.
///
/// Everything here is read-only. Nothing in this file stages, commits, checks
/// out or writes to the repository in any way.
///
/// A session over ssh is asked the same questions through <see
/// cref="SshGitChannel"/>, which runs the same git commands on the machine the
/// user is actually standing on. Every method here takes a <see
/// cref="SessionLocation"/> rather than a path for that reason: a path alone
/// cannot say which computer it belongs to, and answering with the wrong one
/// is exactly the bug this replaced.
/// </summary>
public static class GitStatus
{
    /// <summary>
    /// Long enough for a cold index on a large repository, short enough that a
    /// hung git (a credential prompt on a network remote, a stale lock) cannot
    /// wedge the panel open forever.
    /// </summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    /// <summary>
    /// The repository root containing <paramref name="workingDirectory"/>, or
    /// null when it is not inside one. The path git prints is used verbatim as
    /// the working directory for every later call, so submodules and worktrees
    /// resolve to the repository the user is actually standing in.
    /// </summary>
    public static async Task<SessionLocation?> DiscoverRepoAsync(
        SessionLocation? at, CancellationToken ct = default)
    {
        if (at == null || !at.HasPath)
            return null;

        if (at.IsRemote)
        {
            var channel = await SshGitChannels.GetAsync(at.Remote!, ct);
            if (channel is not { IsUsable: true })
                return null;

            // A remote shell reports ~/work as often as it reports the full
            // path, and git would look for a directory literally called "~".
            string here = PosixPath.ExpandHome(at.Path, channel.Home);
            string remoteRoot = (await channel.RunAsync(
                here, new[] { "git", "rev-parse", "--show-toplevel" }, ct)).Trim();
            return remoteRoot.Length == 0 ? null : at.WithPath(remoteRoot);
        }

        if (!Directory.Exists(at.Path))
            return null;

        var result = await RunAsync(at, ct, "rev-parse", "--show-toplevel");
        if (!result.Ok)
            return null;

        var root = result.StdOut.Trim();
        return root.Length == 0
            ? null
            : at.WithPath(root.Replace('/', Path.DirectorySeparatorChar));
    }

    /// <summary>
    /// Why a machine reached over ssh cannot be read, or null when it can.
    /// Shown instead of a file list, because "not a git repository" would be a
    /// guess when the truth is that nobody has been able to ask.
    /// </summary>
    public static async Task<string?> RemoteProblemAsync(
        RemoteHost host, CancellationToken ct = default)
    {
        if (!SshGitChannels.Enabled)
            return "Reading git over ssh is turned off in Settings.";

        var channel = await SshGitChannels.GetAsync(host, ct);
        if (channel == null)
            return "Reading git over ssh is turned off in Settings.";
        return channel.IsUsable ? null : channel.Problem ?? "The connection could not be opened";
    }

    /// <summary>
    /// The branch name, or a short commit id when the head is detached, or
    /// null when neither can be read (a repository with no commits yet).
    /// </summary>
    public static async Task<string?> CurrentBranchAsync(SessionLocation repoRoot, CancellationToken ct = default)
    {
        var branch = await RunAsync(repoRoot, ct, "rev-parse", "--abbrev-ref", "HEAD");
        if (!branch.Ok)
            return null;

        var name = branch.StdOut.Trim();
        if (name.Length == 0)
            return null;
        if (name != "HEAD")
            return name;

        // Detached: name the commit instead, since "HEAD" tells nobody anything.
        var commit = await RunAsync(repoRoot, ct, "rev-parse", "--short", "HEAD");
        return commit.Ok && commit.StdOut.Trim().Length > 0 ? commit.StdOut.Trim() : null;
    }

    /// <summary>
    /// Every path that differs from HEAD, staged and unstaged alike, newest
    /// git ordering preserved.
    ///
    /// Uses `-z` so paths arrive NUL separated: a filename containing a quote,
    /// a newline or a non-ASCII byte is unparseable from the default output,
    /// and git will happily hand you one.
    /// </summary>
    public static async Task<IReadOnlyList<GitFileChange>> StatusAsync(SessionLocation repoRoot, CancellationToken ct = default)
    {
        var result = await RunAsync(repoRoot, ct,
            "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames");
        if (!result.Ok)
            return Array.Empty<GitFileChange>();

        var changes = new List<GitFileChange>();

        // Records are "XY <path>\0". --no-renames is set above so no record
        // carries the second "\0<oldpath>" field, which keeps the split simple
        // and costs nothing: a rename shows as a delete plus an add, which is
        // what the diff shows anyway.
        foreach (var record in result.StdOut.Split('\0', StringSplitOptions.RemoveEmptyEntries))
        {
            if (record.Length < 4)
                continue;

            char index = record[0];
            char tree = record[1];
            string path = record[3..];
            if (path.Length == 0)
                continue;

            if (index == '?' && tree == '?')
            {
                changes.Add(new GitFileChange { Path = path, Kind = GitChangeKind.Untracked });
                continue;
            }

            if (index == 'U' || tree == 'U' || (index == 'A' && tree == 'A') || (index == 'D' && tree == 'D'))
            {
                changes.Add(new GitFileChange { Path = path, Kind = GitChangeKind.Conflicted });
                continue;
            }

            // A path can be staged AND further modified in the working tree.
            // It is listed once, as staged, because that is the state the next
            // commit would capture; the diff shown for it covers both.
            bool staged = index is not ' ' and not '?';
            char code = staged ? index : tree;

            changes.Add(new GitFileChange
            {
                Path = path,
                Staged = staged,
                Kind = code switch
                {
                    'A' => GitChangeKind.Added,
                    'D' => GitChangeKind.Deleted,
                    'R' => GitChangeKind.Renamed,
                    _ => GitChangeKind.Modified,
                },
            });
        }

        return changes;
    }

    /// <summary>
    /// The unified diff for one path, against HEAD, covering staged and
    /// unstaged changes together.
    ///
    /// An untracked file has nothing to diff against, so git is asked to
    /// compare it with the empty tree via --no-index, which prints it as one
    /// long addition. That is what the user means by "what changed".
    /// </summary>
    public static async Task<string> DiffAsync(
        SessionLocation repoRoot, GitFileChange change, CancellationToken ct = default)
    {
        if (change.Kind == GitChangeKind.Untracked)
        {
            // --no-index exits 1 when the files differ, which is the normal
            // case here, so its exit code is not a failure signal.
            var untracked = await RunAsync(repoRoot, ct, allowFailure: true,
                "diff", "--no-index", "--no-color", "--",
                repoRoot.IsRemote ? "/dev/null" : NullDevice, change.Path);
            return untracked.StdOut;
        }

        var result = await RunAsync(repoRoot, ct,
            "diff", "HEAD", "--no-color", "--", change.Path);
        return result.Ok ? result.StdOut : "";
    }

    /// <summary>
    /// Added and removed line counts for every tracked path that differs from
    /// HEAD, in a single call.
    ///
    /// One `git diff --numstat` replaces one `git diff` per changed file. On a
    /// repository with fifty changed files that is fifty process launches
    /// traded for one, which is the difference between totals that appear
    /// instantly and totals that trickle in.
    ///
    /// Untracked files are absent: git has nothing to compare them against.
    /// <see cref="CountUntrackedAsync"/> handles those.
    ///
    /// Binary files report "-" for both counts and are returned as (0, 0):
    /// a line count of a binary is not a meaningful number to show.
    /// </summary>
    public static async Task<Dictionary<string, (int Added, int Removed)>> NumstatAsync(
        SessionLocation repoRoot, CancellationToken ct = default)
    {
        var totals = new Dictionary<string, (int, int)>(StringComparer.Ordinal);

        // -z so paths are NUL terminated and survive quotes and newlines. In
        // this mode git writes "added	removed	path " per record.
        var result = await RunAsync(repoRoot, ct, "diff", "--numstat", "-z", "HEAD");
        if (!result.Ok)
            return totals;

        foreach (var record in result.StdOut.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = record.Split('	');
            if (parts.Length < 3)
                continue;
            string path = parts[2];
            if (path.Length == 0)
                continue;
            int added = int.TryParse(parts[0], out int a) ? a : 0;
            int removed = int.TryParse(parts[1], out int r) ? r : 0;
            totals[path] = (added, removed);
        }

        return totals;
    }

    /// <summary>
    /// An untracked file's whole content is what a diff would show as added,
    /// so its line count is its added count. Read directly rather than through
    /// git, which would need one --no-index run per file to say the same thing.
    /// </summary>
    public static async Task<int> CountUntrackedAsync(
        SessionLocation repoRoot, string path, CancellationToken ct = default)
    {
        if (repoRoot.IsRemote)
        {
            // Reading the file back over the wire to count its newlines would
            // move the whole file for a number in a list row. wc is on every
            // machine that has a shell.
            var channel = await SshGitChannels.GetAsync(repoRoot.Remote!, ct);
            if (channel is not { IsUsable: true })
                return 0;

            string answer = await channel.RunAsync(
                repoRoot.Path, new[] { "wc", "-l", "--", path }, ct);
            var first = answer.AsSpan().Trim();
            int space = first.IndexOf(' ');
            if (space > 0)
                first = first[..space];
            return int.TryParse(first, out int counted) ? counted : 0;
        }

        try
        {
            string full = Path.Combine(repoRoot.Path, path.Replace('/', Path.DirectorySeparatorChar));
            var info = new FileInfo(full);
            if (!info.Exists)
                return 0;

            // A very large new file is not worth counting line by line to put a
            // number in a title bar.
            if (info.Length > 4 * 1024 * 1024)
                return 0;

            int lines = 0;
            using var reader = new StreamReader(full);
            while (await reader.ReadLineAsync(ct) != null)
                lines++;
            return lines;
        }
        catch
        {
            // Unreadable, locked, or vanished between status and now.
            return 0;
        }
    }

    /// <summary>
    /// Counts the +/- lines in a unified diff, ignoring the `+++` and `---`
    /// file headers, which start with the same characters and are not content.
    /// </summary>
    public static (int Added, int Removed) CountLines(string diff)
    {
        int added = 0, removed = 0;
        foreach (var line in diff.AsSpan().EnumerateLines())
        {
            if (line.StartsWith("+++") || line.StartsWith("---"))
                continue;
            if (line.StartsWith("+"))
                added++;
            else if (line.StartsWith("-"))
                removed++;
        }
        return (added, removed);
    }

    /// <summary>
    /// The platform's empty file, for diffing an untracked path against
    /// nothing. `/dev/null` is what git itself prints in diff headers and it
    /// understands the name on Windows too, but NUL is what actually exists
    /// here, and git accepts either.
    /// </summary>
    private const string NullDevice = "NUL";

    private readonly record struct GitResult(bool Ok, string StdOut, string StdErr);

    private static Task<GitResult> RunAsync(SessionLocation at, CancellationToken ct, params string[] args)
        => RunAsync(at, ct, allowFailure: false, args);

    private static async Task<GitResult> RunAsync(
        SessionLocation at, CancellationToken ct, bool allowFailure, params string[] args)
    {
        if (at.IsRemote)
            return await RunRemoteAsync(at, ct, args);

        return await RunLocalAsync(at.Path, ct, allowFailure, args);
    }

    /// <summary>
    /// Runs git on the far end of an ssh connection.
    ///
    /// There is no exit status here, deliberately. Carrying one back would
    /// need a temporary file on the user's server for every poll, and no
    /// caller in this file distinguishes "git failed" from "git printed
    /// nothing": a directory that is not a repository, a file that is not
    /// there and a clean tree all mean an empty answer, which is what the
    /// panel shows either way. A connection that is genuinely broken is
    /// reported by <see cref="RemoteProblemAsync"/> instead, which is a
    /// different question with a different answer.
    /// </summary>
    private static async Task<GitResult> RunRemoteAsync(
        SessionLocation at, CancellationToken ct, string[] args)
    {
        var channel = await SshGitChannels.GetAsync(at.Remote!, ct);
        if (channel is not { IsUsable: true })
            return new GitResult(false, "", channel?.Problem ?? "no connection");

        var argv = new string[args.Length + 1];
        argv[0] = "git";
        args.CopyTo(argv, 1);

        string output = await channel.RunAsync(at.Path, argv, ct);
        return new GitResult(true, output, "");
    }

    private static async Task<GitResult> RunLocalAsync(
        string workingDirectory, CancellationToken ct, bool allowFailure, params string[] args)
    {
        var psi = new ProcessStartInfo("git")
        {
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        // Never let git stop and ask. In a GUI process a credential or editor
        // prompt has nowhere to draw and nothing to read from, so it would
        // hang until the timeout with no way for the user to see why.
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";
        psi.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        psi.Environment["GCM_INTERACTIVE"] = "never";

        foreach (var arg in args)
            psi.ArgumentList.Add(arg);

        try
        {
            using var process = Process.Start(psi);
            if (process == null)
                return new GitResult(false, "", "git did not start");

            var stdout = process.StandardOutput.ReadToEndAsync(ct);
            var stderr = process.StandardError.ReadToEndAsync(ct);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(Timeout);

            try
            {
                await process.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                return new GitResult(false, "", "git timed out");
            }

            string outText = await stdout;
            string errText = await stderr;
            bool ok = allowFailure || process.ExitCode == 0;
            return new GitResult(ok, outText, errText);
        }
        catch (Exception ex)
        {
            // Most often: git is not installed, or not on this process's PATH.
            // The panel reports that as "git not found" rather than crashing.
            return new GitResult(false, "", ex.Message);
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Already gone, or not ours to kill. Nothing useful to do.
        }
    }
}
