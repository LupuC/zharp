using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Zharp.Core.Remote;
using Zharp.Core.Terminal;

namespace Zharp.App.Controls;

/// <summary>
/// One row in the changed-files list.
///
/// Raises PropertyChanged rather than being replaced when its counts arrive.
/// Rebuilding ItemsSource to refresh a number makes the whole list blink and
/// jump, which is what a refresh looked like before.
/// </summary>
public sealed class DiffFileRow : INotifyPropertyChanged
{
    public required GitFileChange Change { get; init; }
    public required string Badge { get; init; }

    private Brush _badgeBrush = new SolidColorBrush(Colors.Gray);
    public Brush BadgeBrush { get => _badgeBrush; set => Set(ref _badgeBrush, value); }

    private Brush _addBrush = new SolidColorBrush(Colors.Gray);
    public Brush AddBrush { get => _addBrush; set => Set(ref _addBrush, value); }

    private Brush _delBrush = new SolidColorBrush(Colors.Gray);
    public Brush DelBrush { get => _delBrush; set => Set(ref _delBrush, value); }

    public string Path => Change.Path;

    /// <summary>
    /// What the row is labelled. Usually the bare filename, but a repository
    /// full of app/page.tsx, docs/page.tsx and so on would render a column of
    /// identical labels, so those carry enough parent path to tell apart.
    /// Set during the rebuild, where the whole file set is visible at once.
    /// </summary>
    public string Display { get; set; } = "";

    /// <summary>"+12", or blank while the diff has not been read.</summary>
    public string Plus => Change.Added <= 0 ? "" : $"+{Change.Added} ";

    /// <summary>"-3", or blank.</summary>
    public string Minus => Change.Removed <= 0 ? "" : $"-{Change.Removed}";

    /// <summary>Called once the counts have been filled in.</summary>
    public void CountsArrived()
    {
        Raise(nameof(Plus));
        Raise(nameof(Minus));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return;
        field = value;
        Raise(name);
    }

    private void Raise(string? name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>
/// Read-only view of what has changed in the git repository the active session
/// is standing in, shown beside the terminal rather than instead of it.
///
/// Nothing here writes to the repository. There is no stage, no commit, no
/// discard: the terminal is one pane away and is better at all three. This
/// answers "what have I changed" without making you type `git diff` and lose
/// your place.
/// </summary>
public sealed partial class DiffView : UserControl
{
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherQueueTimer _poll;

    private SessionLocation? _repoRoot;
    private SessionLocation? _pendingCwd;
    private CancellationTokenSource? _work;
    /// <summary>
    /// Deliberately not readonly. A List is not observable, so assigning the
    /// SAME reference back to ItemsSource changes nothing on screen: the only
    /// way a ListView notices is a different instance. Clearing and refilling
    /// this one left the previous repository's files on screen forever.
    /// </summary>
    private List<DiffFileRow> _rows = new();
    private string _fontFamily = "Cascadia Mono";

    /// <summary>Fires when the totals change, so the title bar can show them.</summary>
    public event Action<int, int>? TotalsChanged;

    public int TotalAdded { get; private set; }
    public int TotalRemoved { get; private set; }

    private Brush _addFg = new SolidColorBrush(Colors.SeaGreen);
    private Brush _delFg = new SolidColorBrush(Colors.IndianRed);
    private Brush _metaFg = new SolidColorBrush(Colors.Gray);
    private Brush _bodyFg = new SolidColorBrush(Colors.Gray);
    private Brush _gutterFg = new SolidColorBrush(Colors.Gray);

    /// <summary>
    /// A RichTextBlock lays out every line as a Paragraph, and past a couple of
    /// thousand that starts to be felt on open. A diff longer than this is one
    /// to read in the terminal.
    /// </summary>
    private const int MaxLines = 1500;

    /// <summary>
    /// How often the working tree is re-read while the panel is open. Slow
    /// enough that git is not being run constantly, fast enough that saving a
    /// file in an editor shows up without asking.
    /// </summary>
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

    /// <summary>
    /// The same idea over ssh, slowed down. Two seconds is chosen against the
    /// cost of running git on a local disk; the same rate against a machine
    /// across a network is a steady trickle of traffic and remote processes
    /// for a panel nobody may be looking at. Six seconds still catches a save
    /// before you have finished looking away.
    /// </summary>
    private static readonly TimeSpan RemotePollInterval = TimeSpan.FromSeconds(6);

    public DiffView()
    {
        InitializeComponent();

        _poll = _dispatcher.CreateTimer();
        _poll.Interval = PollInterval;
        _poll.IsRepeating = true;
        _poll.Tick += (_, _) => _ = RefreshAsync(quiet: true);

        Loaded += (_, _) => _poll.Start();
        Unloaded += (_, _) => _poll.Stop();
    }

    /// <summary>
    /// The file an agent just wrote, waiting to be selected once the list has
    /// caught up with it. Repo-relative, forward slashes, like git's own paths.
    /// </summary>
    private string? _following;

    /// <summary>
    /// How many more refreshes may go looking for it. git can take a moment to
    /// see a write, but a file that never turns up (ignored, or written outside
    /// the tree) must not sit there hijacking the selection forever.
    /// </summary>
    private int _followTries;

    /// <summary>
    /// Opens the file an AI agent has just written.
    ///
    /// The panel already re-reads the working tree every two seconds, so the
    /// change would appear on its own. What this adds is which file to be
    /// looking at: the agent is the only one who knows that, and being told
    /// turns the panel from a thing you check into a thing you watch.
    /// </summary>
    public async Task FollowAsync(string absolutePath)
    {
        if (_repoRoot is not { } repo)
            return;

        string relative;
        if (repo.IsRemote)
        {
            // An agent running over there reports that machine's paths, which
            // must not be run through Windows path handling: it would turn
            // /home/me/app.ts into C:\home\me\app.ts and then decide the agent
            // was editing outside the repository.
            if (!PosixPath.IsUnder(repo.Path, absolutePath, out relative))
                return;
        }
        else
        {
            string full;
            try
            {
                full = System.IO.Path.GetFullPath(absolutePath);
            }
            catch (Exception)
            {
                return; // not a path we can make sense of
            }

            string root = System.IO.Path.GetFullPath(repo.Path)
                .TrimEnd(System.IO.Path.DirectorySeparatorChar);
            if (!full.StartsWith(root + System.IO.Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
                return; // the agent is editing outside the repository on screen

            relative = full[(root.Length + 1)..].Replace('\\', '/');
        }

        _following = relative;
        _followTries = 3;

        // Quiet, because the file set usually has not changed: the agent edits
        // the same handful of files over and over, and a loud refresh would
        // rebuild the list under the user on every save.
        await RefreshAsync(quiet: true);
    }

    /// <summary>
    /// Selects the followed file once it is actually in the list.
    ///
    /// Separate from the rebuild because most of the time there is no rebuild:
    /// editing a file that was already changed leaves the file set identical,
    /// and the selection still has to move.
    /// </summary>
    private void SelectFollowed()
    {
        if (_following is not { Length: > 0 } want)
            return;

        int index = _rows.FindIndex(r =>
            string.Equals(r.Path, want, StringComparison.OrdinalIgnoreCase));
        if (index < 0)
        {
            // git has not noticed the write yet, so let the next poll look.
            // Give up eventually: some writes never become a change at all.
            if (--_followTries <= 0)
                _following = null;
            return;
        }

        _following = null;
        if (FileList.SelectedIndex != index)
            FileList.SelectedIndex = index;
        FileList.ScrollIntoView(_rows[index]);
    }

    /// <summary>Points the view at wherever the active session is standing,
    /// which may be on another machine.</summary>
    public async Task SetLocationAsync(SessionLocation? where)
    {
        if (Equals(_pendingCwd, where))
            return;
        RememberPlace();
        _pendingCwd = where;

        // A pending follow belongs to the session being left. Carrying it into
        // the next one would open a file the user never asked about.
        _following = null;

        await RefreshAsync();
    }

    /// <summary>
    /// Re-reads the repository.
    ///
    /// <paramref name="quiet"/> is the polling path: it leaves the list and the
    /// open diff alone unless something actually changed, so a refresh every
    /// two seconds is invisible rather than a blink.
    /// </summary>
    public async Task RefreshAsync(bool quiet = false)
    {
        _work?.Cancel();
        var cts = new CancellationTokenSource();
        _work = cts;
        var ct = cts.Token;

        try
        {
            _repoRoot = await GitStatus.DiscoverRepoAsync(_pendingCwd, ct);
            if (ct.IsCancellationRequested)
                return;

            _poll.Interval = _pendingCwd is { IsRemote: true } ? RemotePollInterval : PollInterval;

            if (_repoRoot == null)
            {
                _following = null;
                SetTotals(0, 0);
                await ShowNothingHereAsync(ct);
                return;
            }

            var branch = await GitStatus.CurrentBranchAsync(_repoRoot, ct);
            var changes = await GitStatus.StatusAsync(_repoRoot, ct);
            if (ct.IsCancellationRequested)
                return;

            RepoText.Text = _repoRoot.DisplayName;
            BranchText.Text = branch is { Length: > 0 } ? $"on {branch}" : "";
            ShowHost(_repoRoot.Remote?.Label);

            if (changes.Count == 0)
            {
                SetTotals(0, 0);
                ShowEmpty("No changes", "Nothing differs from HEAD.");
                return;
            }

            // Same set of paths in the same order means nothing to rebuild.
            // Only the counts can have moved, and those update in place.
            bool sameFiles = _rows.Count == changes.Count;
            if (sameFiles)
            {
                for (int i = 0; i < changes.Count; i++)
                {
                    if (_rows[i].Change.Path != changes[i].Path || _rows[i].Change.Kind != changes[i].Kind)
                    {
                        sameFiles = false;
                        break;
                    }
                }
            }

            HideEmpty();

            if (!sameFiles)
            {
                var selectedPath = (FileList.SelectedItem as DiffFileRow)?.Path;

                // Labels that would collide get enough parent path to tell
                // them apart. Counted over the whole set, which is only
                // knowable here rather than on the row itself.
                var byName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                foreach (var change in changes)
                {
                    string name = System.IO.Path.GetFileName(change.Path);
                    byName[name] = byName.TryGetValue(name, out int n) ? n + 1 : 1;
                }

                // A new instance, not a cleared one: see the field's note.
                // Only ever reached when the file set genuinely changed, so
                // rebuilding here costs nothing during a quiet poll.
                _rows = new List<DiffFileRow>();
                foreach (var change in changes)
                    _rows.Add(new DiffFileRow
                    {
                        Change = change,
                        Badge = BadgeFor(change.Kind),
                        BadgeBrush = BadgeBrushFor(change.Kind),
                        AddBrush = _addFg,
                        DelBrush = _delFg,
                        Display = LabelFor(change.Path, byName),
                    });

                FileList.ItemsSource = _rows;

                // Prefer the file an agent has just written, then the file this
                // session was reading, then the file this repository was last
                // left on, then the first. The agent's file goes first because
                // it is the most recent statement of what matters, and picking
                // it here rather than afterwards avoids selecting twice.
                string? want = _following ?? selectedPath;
                if (want == null && _repoRoot != null
                    && _placeInRepo.TryGetValue(_repoRoot.ToString(), out var place))
                    want = place.Path;

                int keep = want == null
                    ? 0
                    : Math.Max(0, _rows.FindIndex(r => r.Path == want));
                FileList.SelectedIndex = _rows.Count == 0 ? -1 : keep;

                // Only scroll when the wanted row is genuinely out of view.
                // ScrollIntoView animates, so calling it unconditionally put a
                // small slide on every single tab switch, including the ones
                // already showing the right row at the top.
                if (_rows.Count > 0 && keep > 0)
                    FileList.ScrollIntoView(_rows[Math.Clamp(keep, 0, _rows.Count - 1)]);
            }
            else
            {
                // Carry the freshly read change records onto the existing rows
                // so the counts below are computed from current data.
                for (int i = 0; i < changes.Count; i++)
                {
                    changes[i].Added = _rows[i].Change.Added;
                    changes[i].Removed = _rows[i].Change.Removed;
                }
            }

            // After the list is settled, whether it was rebuilt or not: an edit
            // to a file already in the list changes nothing about the set, and
            // the selection still has to move to it.
            SelectFollowed();

            _ = FillCountsAsync(ct, quiet);
        }
        catch (OperationCanceledException)
        {
            // Superseded by a newer refresh; that one paints.
        }
        catch (Exception ex)
        {
            App.Log($"diff: refresh failed: {ex.Message}");
            ShowEmpty("Could not read the repository", ex.Message);
        }
    }

    /// <summary>
    /// Reads each file's diff to fill in its +/- counts, updating rows in place
    /// as they arrive. Runs after the list is on screen: a repository with
    /// hundreds of changed files would otherwise show nothing until the last
    /// diff had been read.
    /// </summary>
    private async Task FillCountsAsync(CancellationToken ct, bool quiet)
    {
        if (_repoRoot == null)
            return;

        if (_repoRoot.IsRemote)
        {
            await FillCountsRemotelyAsync(_repoRoot, ct, quiet);
            return;
        }

        int added = 0, removed = 0;

        foreach (var row in _rows.ToArray())
        {
            if (ct.IsCancellationRequested)
                return;

            int a = 0, r = 0;
            try
            {
                var diff = await GitStatus.DiffAsync(_repoRoot, row.Change, ct);
                (a, r) = GitStatus.CountLines(StripHeaders(diff));
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                // Unreadable file: count it as nothing rather than stop.
            }

            added += a;
            removed += r;

            bool moved = row.Change.Added != a || row.Change.Removed != r;
            row.Change.Added = a;
            row.Change.Removed = r;
            if (moved || !quiet)
                row.CountsArrived();
        }

        if (!ct.IsCancellationRequested)
            SetTotals(added, removed);
    }

    /// <summary>
    /// The same counts, in one question instead of one per file.
    ///
    /// Reading a diff per row is affordable when each one is a local process
    /// and the answer comes back in single milliseconds. Over ssh it is a
    /// round trip each, repeated every poll, so twenty changed files would
    /// mean twenty crossings of the network to put small grey numbers beside
    /// twenty rows. `git diff --numstat` answers for the whole tree at once.
    ///
    /// Untracked files are absent from it, because git has nothing to compare
    /// them against, and are counted individually. There are usually none, and
    /// a handful at most.
    /// </summary>
    private async Task FillCountsRemotelyAsync(
        SessionLocation repo, CancellationToken ct, bool quiet)
    {
        var totals = await GitStatus.NumstatAsync(repo, ct);
        if (ct.IsCancellationRequested)
            return;

        int added = 0, removed = 0;

        foreach (var row in _rows.ToArray())
        {
            if (ct.IsCancellationRequested)
                return;

            int a = 0, r = 0;
            if (totals.TryGetValue(row.Path, out var counted))
                (a, r) = counted;
            else if (row.Change.Kind == GitChangeKind.Untracked)
                a = await GitStatus.CountUntrackedAsync(repo, row.Path, ct);

            added += a;
            removed += r;

            bool moved = row.Change.Added != a || row.Change.Removed != r;
            row.Change.Added = a;
            row.Change.Removed = r;
            if (moved || !quiet)
                row.CountsArrived();
        }

        if (!ct.IsCancellationRequested)
            SetTotals(added, removed);
    }

    private void SetTotals(int added, int removed)
    {
        if (TotalAdded == added && TotalRemoved == removed)
            return;
        TotalAdded = added;
        TotalRemoved = removed;
        TotalsChanged?.Invoke(added, removed);
    }

    /// <summary>
    /// Where each repository was left: which file was open, and how far down
    /// its diff. One panel serves every session, so without this, switching
    /// tab and back dropped you at the top of the first file every time.
    /// </summary>
    private readonly Dictionary<string, (string Path, double Scroll)> _placeInRepo =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// A label that is unique within the current file set: the bare filename
    /// when nothing else shares it, otherwise the last directory too.
    /// </summary>
    private static string LabelFor(string path, Dictionary<string, int> byName)
    {
        string name = System.IO.Path.GetFileName(path);
        if (name.Length == 0)
            return path;
        if (byName.TryGetValue(name, out int n) && n <= 1)
            return name;

        int slash = path.LastIndexOf('/');
        if (slash <= 0)
            return name;
        int parent = path.LastIndexOf('/', slash - 1);
        return parent < 0 ? path : path[(parent + 1)..];
    }

    /// <summary>
    /// Keeps the remembered place current as the user reads, so that a switch
    /// away does not depend on catching them at the right moment.
    /// </summary>
    private void OnDiffScrollChanged(object sender, ScrollViewerViewChangedEventArgs e)
    {
        if (!e.IsIntermediate)
            RememberPlace();
    }

    /// <summary>Stores where the current repository is being left.</summary>
    private void RememberPlace()
    {
        if (_repoRoot is not { } repo)
            return;
        if (FileList.SelectedItem is not DiffFileRow row)
            return;
        _placeInRepo[repo.ToString()] = (row.Path, DiffScroll.VerticalOffset);
    }

    private string? _shownPath;
    private string? _shownDiff;

    private async void OnFileSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (FileList.SelectedItem is not DiffFileRow row || _repoRoot == null)
        {
            DiffText.Blocks.Clear();
            GutterCanvas.Children.Clear();
            _shownPath = null;
            return;
        }

        try
        {
            var diff = StripHeaders(await GitStatus.DiffAsync(_repoRoot, row.Change));

            // Re-rendering identical text would drop the user's selection and
            // reset the scroll position on every poll.
            if (_shownPath == row.Path && _shownDiff == diff)
                return;

            bool sameFile = _shownPath == row.Path;
            _shownPath = row.Path;
            _shownDiff = diff;
            RenderDiff(diff, keepScroll: sameFile);

            // Coming back to a repository lands where it was left rather than
            // at the top. Queued rather than set now: the ScrollViewer cannot
            // move past content it has not laid out yet, so the offset has to
            // wait for the paragraphs just added to exist.
            if (!sameFile && _repoRoot != null
                && _placeInRepo.TryGetValue(_repoRoot.ToString(), out var place)
                && place.Path == row.Path && place.Scroll > 0)
            {
                double target = place.Scroll;
                _dispatcher.TryEnqueue(DispatcherQueuePriority.Low,
                    () => DiffScroll.ChangeView(null, target, null, disableAnimation: true));
            }
        }
        catch (Exception ex)
        {
            App.Log($"diff: could not read {row.Path}: {ex.Message}");
        }
    }

    /// <summary>
    /// Drops git's file-level preamble: the `diff --git` line, the index hash,
    /// the mode lines and the `---`/`+++` pair. They name the file the user
    /// just clicked and say nothing else, and the `---`/`+++` pair reads as a
    /// large deletion followed by a large addition.
    ///
    /// Hunk headers stay. `@@ -12,7 +12,9 @@` is the only thing telling you
    /// where in the file you are.
    /// </summary>
    private static string StripHeaders(string diff)
    {
        var kept = new List<string>();
        foreach (var raw in diff.Split('\n'))
        {
            string line = raw.TrimEnd('\r');
            if (line.StartsWith("diff --git ", StringComparison.Ordinal)
                || line.StartsWith("index ", StringComparison.Ordinal)
                || line.StartsWith("--- ", StringComparison.Ordinal)
                || line.StartsWith("+++ ", StringComparison.Ordinal)
                || line is "--- /dev/null" or "+++ /dev/null"
                || line.StartsWith("new file mode ", StringComparison.Ordinal)
                || line.StartsWith("deleted file mode ", StringComparison.Ordinal)
                || line.StartsWith("old mode ", StringComparison.Ordinal)
                || line.StartsWith("new mode ", StringComparison.Ordinal)
                || line.StartsWith("similarity index ", StringComparison.Ordinal)
                || line.StartsWith("rename from ", StringComparison.Ordinal)
                || line.StartsWith("rename to ", StringComparison.Ordinal))
                continue;
            kept.Add(line);
        }

        // A leading blank line from the stripped preamble is just a gap.
        while (kept.Count > 0 && kept[0].Length == 0)
            kept.RemoveAt(0);

        return string.Join('\n', kept);
    }

    /// <summary>Line number for each paragraph, by paragraph index.</summary>
    private readonly List<string> _numbers = new();

    private void RenderDiff(string diff, bool keepScroll)
    {
        double scroll = keepScroll ? DiffScroll.VerticalOffset : 0;
        var font = new FontFamily(_fontFamily);

        DiffText.Blocks.Clear();
        GutterCanvas.Children.Clear();
        _numbers.Clear();
        DiffText.FontFamily = font;

        // Line numbers come from the hunk headers rather than a running count:
        // a diff is a handful of windows into a file, and the @@ line is the
        // only statement of where each window begins.
        int oldLine = 0, newLine = 0;
        int widest = 0;
        int count = 0;

        foreach (var raw in diff.Split('\n'))
        {
            if (count++ >= MaxLines)
            {
                Emit("", "... truncated at " + MaxLines + " lines. Read the rest with git diff.", _metaFg);
                break;
            }

            string text = raw;

            // Hunk headers are dropped: they exist to say where in the file you
            // are, and the gutter says that on every line. A blank row marks the
            // jump instead of leaving @@ syntax on screen.
            if (text.StartsWith("@@", StringComparison.Ordinal))
            {
                (oldLine, newLine) = ParseHunk(text, oldLine, newLine);
                if (DiffText.Blocks.Count > 0)
                    Emit("", " ", _metaFg);
                continue;
            }

            Brush fg;
            string number;

            if (text.StartsWith("+", StringComparison.Ordinal))
            {
                fg = _addFg;
                number = newLine.ToString();
                newLine++;
            }
            else if (text.StartsWith("-", StringComparison.Ordinal))
            {
                fg = _delFg;
                // A removed line carries its OLD file number: it does not exist
                // in the new file, so a new-file number would point at a line
                // that is something else entirely.
                number = oldLine.ToString();
                oldLine++;
            }
            else if (text.StartsWith("\\ No newline", StringComparison.Ordinal))
            {
                fg = _metaFg;
                number = "";
            }
            else
            {
                fg = _bodyFg;
                number = newLine.ToString();
                oldLine++;
                newLine++;
            }

            widest = Math.Max(widest, number.Length);
            Emit(number, text.Length == 0 ? " " : text, fg);
        }

        // Reserve the column before measuring, or the text would reflow the
        // moment the numbers appeared and every measurement would be stale.
        GutterColumn.Width = new GridLength(Math.Max(2, widest) * 8.0 + 18.0);

        PlaceGutter();

        if (keepScroll)
            DiffScroll.ChangeView(null, scroll, null, disableAnimation: true);
        else
            DiffScroll.ChangeView(0, 0, null, disableAnimation: true);
    }

    private void Emit(string number, string text, Brush fg)
    {
        _numbers.Add(number);
        var para = new Paragraph { Margin = new Thickness(0) };
        para.Inlines.Add(new Run { Text = text, Foreground = fg });
        DiffText.Blocks.Add(para);
    }

    /// <summary>
    /// Puts every line number level with the paragraph it belongs to.
    ///
    /// The Y is measured, not computed. Asking a paragraph's first TextPointer
    /// for its character rect gives where that line actually rendered, which
    /// already accounts for however many rows the line above it wrapped onto.
    /// That is the whole trick, and it is why wrapping and a separate gutter
    /// can coexist here at all.
    /// </summary>
    private void PlaceGutter()
    {
        GutterCanvas.Children.Clear();
        if (DiffText.Blocks.Count == 0)
            return;

        double width = GutterColumn.Width.Value;

        for (int i = 0; i < DiffText.Blocks.Count && i < _numbers.Count; i++)
        {
            string number = _numbers[i];
            if (number.Length == 0)
                continue;

            if (DiffText.Blocks[i] is not Paragraph para)
                continue;

            double y;
            try
            {
                // Forward from the paragraph's start: the top-left of its first
                // character, in the RichTextBlock's own coordinates.
                var rect = para.ContentStart.GetCharacterRect(LogicalDirection.Forward);
                y = rect.Top;
            }
            catch
            {
                continue; // not realised yet; the next layout pass catches it
            }

            var label = new TextBlock
            {
                Text = number,
                Foreground = _gutterFg,
                FontFamily = new FontFamily(_fontFamily),
                FontSize = 12.5,
                LineHeight = 17,
                TextAlignment = TextAlignment.Right,
                Width = width - 10,
                IsHitTestVisible = false,
            };
            Canvas.SetLeft(label, 0);
            Canvas.SetTop(label, y);
            GutterCanvas.Children.Add(label);
        }
    }

    /// <summary>
    /// The diff reflowed, so every measured Y is stale. Re-measuring on the
    /// control's own SizeChanged covers a window resize, the splitter being
    /// dragged and a font change alike, without any of them needing to know
    /// about the gutter.
    /// </summary>
    private void OnDiffTextSizeChanged(object sender, SizeChangedEventArgs e) => PlaceGutter();

    /// <summary>
    /// Reads "@@ -12,7 +34,9 @@" and returns the first old and new line the
    /// hunk covers. A malformed header leaves the counters where they were,
    /// which keeps the numbering plausible rather than resetting it to zero.
    /// </summary>
    private static (int Old, int New) ParseHunk(string header, int oldLine, int newLine)
    {
        try
        {
            int minus = header.IndexOf('-');
            int plus = header.IndexOf('+', minus + 1);
            int end = header.IndexOf("@@", 2, StringComparison.Ordinal);
            if (minus < 0 || plus < 0 || end < 0)
                return (oldLine, newLine);

            int o = int.Parse(header[(minus + 1)..plus].Trim().Split(',')[0]);
            int n = int.Parse(header[(plus + 1)..end].Trim().Split(',')[0]);
            return (o, n);
        }
        catch
        {
            return (oldLine, newLine);
        }
    }

    private static void PutOnClipboard(string text)
    {
        if (string.IsNullOrEmpty(text))
            return;
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
    }

    /// <summary>
    /// Copies the selection. The numbers are Canvas children, not text, so a
    /// selection here is the diff and nothing else.
    /// </summary>
    private void OnCopySelectionClick(object sender, RoutedEventArgs e) =>
        PutOnClipboard(DiffText.SelectedText);

    /// <summary>Copies the selected file's whole diff.</summary>
    private void OnCopyClick(object sender, RoutedEventArgs e) =>
        PutOnClipboard(_shownDiff ?? "");

    /// <summary>
    /// Takes the diff colours from the terminal's own palette, so a diff in
    /// gruvbox looks like gruvbox. ANSI 2 and 1 are the green and red every
    /// theme defines, and are what git itself uses in the pane next door.
    /// </summary>
    public void SetPalette(Palette palette)
    {
        _addFg = new SolidColorBrush(FromRgb(palette.Colors[2]));
        _delFg = new SolidColorBrush(FromRgb(palette.Colors[1]));
        _bodyFg = new SolidColorBrush(FromRgb(palette.DefaultForeground));
        _metaFg = new SolidColorBrush(WithAlpha(palette.DefaultForeground, 0x77));
        // Dimmer than the meta colour: the gutter is scaffolding, and it sits
        // beside every single line.
        _gutterFg = new SolidColorBrush(WithAlpha(palette.DefaultForeground, 0x4D));

        foreach (var row in _rows)
        {
            row.AddBrush = _addFg;
            row.DelBrush = _delFg;
            row.BadgeBrush = BadgeBrushFor(row.Change.Kind);
        }

        if (_shownDiff is { } current)
            RenderDiff(current, keepScroll: true);
    }

    /// <summary>Matches the terminal's font, so the diff reads as the same surface.</summary>
    public void SetFontFamily(string family)
    {
        if (string.IsNullOrWhiteSpace(family) || _fontFamily == family)
            return;
        _fontFamily = family;
        if (_shownDiff is { } current)
            RenderDiff(current, keepScroll: true);
    }

    public void SetUiZoom(double zoom)
    {
        _uiZoom = zoom <= 0 ? 1 : zoom;
        ChromeZoom.Apply(this, zoom);
        ApplyFileListHeight(_fileListHeight);
    }

    // ------------------------------------------------------------ file list size

    private double _uiZoom = 1;
    private double _fileListHeight = 160;
    private bool _resizing;
    private double _dragStartY;
    private double _dragStartHeight;

    /// <summary>Smallest useful list: about two rows plus its padding.</summary>
    private const double MinFileListHeight = 64;

    /// <summary>And the diff always keeps this much, however far you drag.</summary>
    private const double MinDiffHeight = 120;

    /// <summary>
    /// Sets the stored height, in unzoomed pixels, so it survives a zoom change
    /// the same way the panel's own width does.
    /// </summary>
    public void SetFileListHeight(double height)
    {
        _fileListHeight = height <= 0 ? 160 : height;
        ApplyFileListHeight(_fileListHeight);
    }

    /// <summary>The height actually in use, unzoomed, for saving.</summary>
    public double FileListHeight => _fileListHeight;

    private void ApplyFileListHeight(double unzoomed)
    {
        double wanted = unzoomed * _uiZoom;
        FileListRow.Height = new GridLength(Clamp(wanted));
    }

    /// <summary>
    /// Keeps the list usable and the diff visible. Done against the panel's
    /// current height, so shrinking the window cannot leave the diff with no
    /// room at all.
    /// </summary>
    private double Clamp(double height)
    {
        double available = ActualHeight - HeaderBar.ActualHeight - MinDiffHeight;
        double max = Math.Max(MinFileListHeight, available);
        return Math.Clamp(height, MinFileListHeight, max);
    }

    private void OnFileListSplitterPressed(object sender, PointerRoutedEventArgs e)
    {
        _resizing = true;
        _dragStartY = e.GetCurrentPoint(this).Position.Y;
        _dragStartHeight = FileList.ActualHeight;
        ((UIElement)sender).CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnFileListSplitterMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizing)
            return;
        double y = e.GetCurrentPoint(this).Position.Y;
        FileListRow.Height = new GridLength(Clamp(_dragStartHeight + (y - _dragStartY)));
        e.Handled = true;
    }

    private void OnFileListSplitterReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizing)
            return;
        _resizing = false;
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);

        // Stored unzoomed, so the panel looks the same at any zoom.
        _fileListHeight = FileList.ActualHeight / _uiZoom;
        FileListHeightChanged?.Invoke(_fileListHeight);
        e.Handled = true;
    }

    private void OnFileListSplitterCaptureLost(object sender, PointerRoutedEventArgs e) =>
        _resizing = false;

    /// <summary>Raised when a drag ends, so the window can save it.</summary>
    public event Action<double>? FileListHeightChanged;

    private static Color FromRgb(uint rgb) => Color.FromArgb(
        0xFF, (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    private static Color WithAlpha(uint rgb, byte alpha) => Color.FromArgb(
        alpha, (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

    private static string BadgeFor(GitChangeKind kind) => kind switch
    {
        GitChangeKind.Added => "A",
        GitChangeKind.Deleted => "D",
        GitChangeKind.Renamed => "R",
        GitChangeKind.Untracked => "?",
        GitChangeKind.Conflicted => "!",
        _ => "M",
    };

    private Brush BadgeBrushFor(GitChangeKind kind) => kind switch
    {
        GitChangeKind.Added or GitChangeKind.Untracked => _addFg,
        GitChangeKind.Deleted or GitChangeKind.Conflicted => _delFg,
        _ => _metaFg,
    };

    private void ShowEmpty(string title, string body)
    {
        EmptyTitle.Text = title;
        EmptyBody.Text = body;
        EmptyState.Visibility = Visibility.Visible;
        FileList.Visibility = Visibility.Collapsed;
        DiffScroll.Visibility = Visibility.Collapsed;
        DiffText.Blocks.Clear();
        GutterCanvas.Children.Clear();
        _rows.Clear();
        _shownPath = null;
        _shownDiff = null;
    }

    private void HideEmpty()
    {
        EmptyState.Visibility = Visibility.Collapsed;
        FileList.Visibility = Visibility.Visible;
        DiffScroll.Visibility = Visibility.Visible;
    }

    /// <summary>
    /// Says why there is no file list, which over ssh is rarely "not a git
    /// repository".
    ///
    /// The distinction matters because each of these has a different thing the
    /// user can do about it, and the panel used to answer all of them by
    /// showing the last local repository it had seen: the one wrong answer
    /// that looks exactly like a right one.
    /// </summary>
    private async Task ShowNothingHereAsync(CancellationToken ct)
    {
        var at = _pendingCwd;
        ShowHost(at?.Remote?.Label);

        if (at is not { IsRemote: true })
        {
            ShowEmpty("Not a git repository",
                "Open a session inside one and this fills in.");
            return;
        }

        string host = at.Remote!.Label;
        RepoText.Text = "";
        BranchText.Text = "";

        if (!at.Remote.CanConnect)
        {
            ShowEmpty($"Connected to {host}",
                "Zharp did not see the ssh command that got here, so it has no way to reach the same machine on its own.");
            return;
        }

        if (await GitStatus.RemoteProblemAsync(at.Remote, ct) is { Length: > 0 } problem)
        {
            ShowEmpty($"Cannot read git on {host}", problem);
            return;
        }

        if (!at.HasPath)
        {
            ShowEmpty($"Somewhere on {host}",
                "The shell over there has not said which directory it is in. Zharp reads OSC 7, and the window title as a fallback.");
            return;
        }

        ShowEmpty("Not a git repository",
            $"{at.Path} on {host} is not inside one.");
    }

    /// <summary>
    /// Names the machine in the header while the panel is showing another
    /// computer's work. Absent for a local repository, which is most of them:
    /// a chip saying "this machine" on every session would be noise.
    /// </summary>
    private void ShowHost(string? label)
    {
        bool remote = !string.IsNullOrEmpty(label);
        HostChip.Visibility = remote ? Visibility.Visible : Visibility.Collapsed;
        HostText.Text = label ?? "";
    }

    private async void OnRefreshClick(object sender, RoutedEventArgs e) => await RefreshAsync();
}
