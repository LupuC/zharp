using System.Diagnostics;
using System.Text;

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
    public static async Task<string?> DiscoverRepoAsync(string? workingDirectory, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(workingDirectory) || !Directory.Exists(workingDirectory))
            return null;

        var result = await RunAsync(workingDirectory, ct, "rev-parse", "--show-toplevel");
        if (!result.Ok)
            return null;

        var root = result.StdOut.Trim();
        return root.Length == 0 ? null : root.Replace('/', Path.DirectorySeparatorChar);
    }

    /// <summary>
    /// The branch name, or a short commit id when the head is detached, or
    /// null when neither can be read (a repository with no commits yet).
    /// </summary>
    public static async Task<string?> CurrentBranchAsync(string repoRoot, CancellationToken ct = default)
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
    public static async Task<IReadOnlyList<GitFileChange>> StatusAsync(string repoRoot, CancellationToken ct = default)
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
        string repoRoot, GitFileChange change, CancellationToken ct = default)
    {
        if (change.Kind == GitChangeKind.Untracked)
        {
            // --no-index exits 1 when the files differ, which is the normal
            // case here, so its exit code is not a failure signal.
            var untracked = await RunAsync(repoRoot, ct, allowFailure: true,
                "diff", "--no-index", "--no-color", "--", NullDevice, change.Path);
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
        string repoRoot, CancellationToken ct = default)
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
        string repoRoot, string path, CancellationToken ct = default)
    {
        try
        {
            string full = Path.Combine(repoRoot, path.Replace('/', Path.DirectorySeparatorChar));
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

    private static Task<GitResult> RunAsync(string workingDirectory, CancellationToken ct, params string[] args)
        => RunAsync(workingDirectory, ct, allowFailure: false, args);

    private static async Task<GitResult> RunAsync(
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
