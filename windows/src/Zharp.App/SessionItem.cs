using System.ComponentModel;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Zharp.App.Controls;
using Zharp.Core.Terminal;

namespace Zharp.App;

/// <summary>
/// One tab-list entry: either a terminal session (with live current-directory
/// subtitle and AI-agent detection) or an embedded page like Settings.
/// </summary>
public sealed class SessionItem : INotifyPropertyChanged
{
    private static readonly string Home =
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>AI coding agents recognized from commands and titles, each
    /// with its logo glyph (brand icons in the bundled font) and color.
    /// First match wins.</summary>
    private static readonly (string Match, string Name, string Glyph, Color Color)[] KnownAgents =
    [
        ("claude", "Claude Code", "", Color.FromArgb(0xFF, 0xD9, 0x77, 0x57)),
        ("opencode", "OpenCode", "", Color.FromArgb(0xFF, 0x7C, 0x8C, 0xF8)),
        ("codex", "Codex", "", Color.FromArgb(0xFF, 0x74, 0xAA, 0x9C)),
        ("gemini", "Gemini CLI", "", Color.FromArgb(0xFF, 0x4E, 0x86, 0xF7)),
        ("aider", "Aider", "", Color.FromArgb(0xFF, 0x00, 0xA6, 0x7D)),
    ];

    /// <summary>Status line shown after an agent finishes working.</summary>
    private const string DoneStatus = "✓ Done";

    private string _subtitle;
    private bool _titleIsCwd;
    private bool _showPath = true;
    private int _agent = -1;
    private double _zoom = 1.0;

    public TerminalSession? Session { get; }
    public TerminalView? View { get; }

    /// <summary>The owning window's "shell exited, close this tab" handler.
    /// Held here so a window handing the tab to another window can unhook it.</summary>
    internal Action<int>? ExitHandler { get; set; }

    /// <summary>What gets shown in the content area when this tab is active.</summary>
    public FrameworkElement Content { get; }

    /// <summary>Tabler glyph for the tab icon.</summary>
    public string IconGlyph { get; }

    public bool IsSettings => Session == null;

    private static int _nextId;

    /// <summary>Identifies this tab to things outside the app that have to name
    /// it later, which today means a desktop notification's click target.</summary>
    public int Id { get; } = Interlocked.Increment(ref _nextId);

    /// <summary>
    /// Whether the changes panel is open for THIS session.
    ///
    /// The panel is one control in the window, but it belongs to a session:
    /// each one is its own workspace, in its own repository, and opening the
    /// diff in one is not a statement about any of the others.
    /// </summary>
    public bool DiffOpen { get; set; }

    /// <summary>Fixed display name (shell name / page name).</summary>
    public string Title { get; }

    /// <summary>ShellDiscovery id this tab was opened with; null = the default
    /// shell. Persisted so session restore reopens the same flavor.</summary>
    public string? ShellId { get; }

    /// <summary>Abbreviated working directory ("~", "~\src\app") or a fixed caption.</summary>
    public string Subtitle
    {
        get => _subtitle;
        private set
        {
            if (_subtitle == value)
                return;
            _subtitle = value;
            NotifyDisplayChanged();
        }
    }

    private string? _lastCommand;

    /// <summary>Card name: the last command run in the session ("New session"
    /// until one runs), or the agent's name while an AI agent owns the tab.</summary>
    private string EffectiveName =>
        _agent >= 0 ? KnownAgents[_agent].Name : _lastCommand ?? "New session";

    /// <summary>Card first line, per the sidebar title-mode setting.</summary>
    public string DisplayTitle =>
        IsSettings ? Title : _titleIsCwd ? _subtitle : EffectiveName;

    private string? _agentStatus;

    /// <summary>Card second line: a working agent's live status line
    /// ("✳ Infusing… (10s · ↓ 452 tokens)"), else the usual counterpart of
    /// the first line.</summary>
    public string DisplaySubtitle =>
        IsSettings ? _subtitle
        : _agentStatus ?? (_titleIsCwd ? EffectiveName : _subtitle);

    /// <summary>Session name for the hover card (shell name / "Claude" / page name).</summary>
    public string SessionName => IsSettings ? Title : EffectiveName;

    /// <summary>Kind row for the hover card: the shell name (the agent's full
    /// name already lives in the card title).</summary>
    public string KindLabel => IsSettings ? "Settings" : Title;

    /// <summary>Logo glyph of the detected agent (brand icons in the font).</summary>
    public string AgentGlyph => _agent >= 0 ? KnownAgents[_agent].Glyph : "";

    public Visibility SubtitleVisibility =>
        IsSettings || _showPath || _agentStatus != null ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Overflow direction per line: paths keep their tail visible,
    /// commands and status lines keep their head.</summary>
    public bool TitleTailFirst => IsSettings || _titleIsCwd;
    public bool SubtitleTailFirst => IsSettings || (_agentStatus == null && !_titleIsCwd);

    /// <summary>Compact text for horizontal pill tabs.</summary>
    public string CompactTitle => IsSettings ? Title : EffectiveName;

    public Visibility StandardIconVisibility => _agent >= 0 ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ClaudeIconVisibility => _agent >= 0 ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>Badge color of the detected agent (bound by the icon glyphs).</summary>
    public SolidColorBrush AgentBrush { get; } = new(KnownAgents[0].Color);

    /// <summary>The raw title the shell set via OSC (full exe path etc.) - tooltip only.</summary>
    public string NativeTitle => Session?.Title ?? Title;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Creates a terminal tab.</summary>
    public SessionItem(TerminalSession session, TerminalView view, string displayName, DispatcherQueue dispatcher,
        string? shellId = null)
    {
        Session = session;
        View = view;
        Content = view;
        Title = displayName;
        ShellId = shellId;
        _dispatcher = dispatcher;
        IconGlyph = "\uEBEF"; // terminal-2
        _subtitle = Abbreviate(session.WorkingDirectory);

        session.WorkingDirectoryChanged += cwd =>
            dispatcher.TryEnqueue(() => Subtitle = Abbreviate(cwd));
        session.CommandExecuted += command =>
            dispatcher.TryEnqueue(() =>
            {
                // Each executed command is authoritative: launching an agent
                // sets the badge, running anything else clears it.
                bool changed = SetAgent(DetectAgentFromCommand(command));
                if (_lastCommand != command)
                {
                    _lastCommand = command;
                    changed = true;
                }
                if (changed)
                    NotifyDisplayChanged();
            });
        session.TitleChanged += title =>
            dispatcher.TryEnqueue(() =>
            {
                // Titles only SET an agent (a matching name proves one runs).
                // They never clear: agents like Claude Code replace the title
                // with a task summary that carries no product name.
                int agent = DetectAgent(title);
                if (agent >= 0 && SetAgent(agent))
                    NotifyDisplayChanged();
                Notify(nameof(NativeTitle));
            });
        session.OutputArrived += () =>
        {
            // Live agent status ("✳ Infusing… (10s · ↓ 452 tokens)"): scrape
            // the visible screen for the spinner row, throttled, only while
            // an agent is active. Runs on the pty thread; UI via dispatcher.
            //
            // Only until the agent introduces itself. Once one is reporting its
            // own state there is nothing here worth reading: the screen can say
            // that it is busy, and never that it is waiting on you.
            if (_agent < 0 || _reports)
                return;
            long now = Environment.TickCount64;
            if (now - _lastStatusScrape < 250)
                return;
            _lastStatusScrape = now;
            string? status = ScrapeAgentStatus(session.Emulator);
            dispatcher.TryEnqueue(() => ApplyAgentStatus(status));
        };
        session.AgentReported += payload =>
        {
            if (AgentReport.Parse(payload) is { } report)
                dispatcher.TryEnqueue(() => ApplyReport(report));
        };
        session.PromptReturned += () => dispatcher.TryEnqueue(AgentFinished);

        // Typing into a session whose agent is waiting is the answer to it.
        // The badge is about a question you have not seen; you are answering
        // it. This replaces asking the agent to tell us, which on Codex meant
        // a process for every tool call it made.
        session.UserTyped += () => dispatcher.TryEnqueue(() =>
        {
            if (_needsAttention)
                NeedsAttention = false;
        });

        // The other transport. Agents that cannot write to the terminal drop
        // their reports in a directory instead, and the one addressed to this
        // session is the one carrying its key. Same report, same handler from
        // here on: the two differ only in how they travelled.
        _spoolHandler = (key, report) =>
        {
            if (key == session.SessionKey)
                dispatcher.TryEnqueue(() => ApplyReport(report));
        };
        AgentSpool.Reported += _spoolHandler;
    }

    /// <summary>Held so it can be unhooked; the spool outlives any one tab.</summary>
    private readonly Action<string, AgentReport>? _spoolHandler;

    /// <summary>
    /// The shell is back at its prompt, so nothing is running in the foreground
    /// and any agent this tab was showing has exited.
    ///
    /// The agent's own "session ended" hook is not enough on its own. It fires
    /// while the process is tearing down, which is the worst moment to ask it
    /// to write to the terminal, and quitting Claude left a tab counting up
    /// "Working" forever. The prompt coming back cannot be missed, needs no
    /// cooperation from the agent, and works just as well for the agents that
    /// report nothing at all.
    /// </summary>
    private void AgentFinished()
    {
        if (_agent < 0)
            return;
        NeedsAttention = false;
        if (SetAgent(-1))
            NotifyDisplayChanged();
    }

    /// <summary>
    /// True once this session's agent has reported its own state at least once.
    /// From then on the screen scrape is off for good, including across the
    /// quiet stretches between turns: falling back mid-session would let the
    /// two disagree, and the guess would win whenever it spoke last.
    /// </summary>
    private bool _reports;

    /// <summary>Raised when this session starts or stops needing you.</summary>
    public event Action<SessionItem>? AttentionChanged;

    private bool _needsAttention;

    /// <summary>
    /// Whether the agent here is blocked on you rather than working. The one
    /// state worth showing on a tab you are not looking at.
    /// </summary>
    public bool NeedsAttention
    {
        get => _needsAttention;
        private set
        {
            if (_needsAttention == value)
                return;
            _needsAttention = value;
            Notify(nameof(NeedsAttention));
            Notify(nameof(AttentionVisibility));
            Notify(nameof(SubtitleTint));
            Notify(nameof(SubtitleBold));
            Notify(nameof(SubtitleOpacity));
            AttentionChanged?.Invoke(this);
        }
    }

    public Visibility AttentionVisibility =>
        _needsAttention ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>
    /// You are looking at this tab, so it has stopped being news. The status
    /// line still says what the agent wants; only the badge goes, because a
    /// badge on the tab you are already reading is just decoration.
    /// </summary>
    public void MarkSeen() => NeedsAttention = false;

    /// <summary>The file the agent last wrote, for whoever wants to follow along.</summary>
    public event Action<SessionItem, string>? AgentTouchedFile;

    private void ApplyReport(AgentReport report)
    {
        _reports = true;
        _lastEvent = report.Event;
        _stateSince = DateTime.UtcNow;

        // A turn begins at the prompt. Everything after it is measured from
        // there, so "how long has this been going" survives the agent moving
        // from tool to tool.
        if (report.Event is AgentEvent.Prompt or AgentEvent.Start)
            _turnStart = _stateSince;

        if (report.Event == AgentEvent.End)
        {
            // The agent is gone. The badge, the status line and any standing
            // request for attention go with it.
            NeedsAttention = false;
            if (SetAgent(-1))
                NotifyDisplayChanged();
            return;
        }

        // The report names its own agent, so a tab launched in some way the
        // command sniffing cannot read still gets the right logo: through a
        // wrapper script, resumed by the shell's history, started by a task
        // runner. Being told beats inferring.
        //
        // An agent we carry no logo for keeps whatever badge it already had.
        // Clearing it would punish a new agent for being new, and its status
        // line still works either way.
        int agent = IndexOfAgent(report.Agent);
        if (agent >= 0 && SetAgent(agent))
            NotifyDisplayChanged();

        bool wasBlocked = _needsAttention;
        NeedsAttention = report.NeedsAttention;

        // "Working" has nothing to say unless it is unsticking a stale "waiting
        // for you". The line already on screen is the more specific one, and
        // the batch that just resolved is usually the very edit it names.
        bool keepSpecificLine =
            report.Event == AgentEvent.Working && !wasBlocked && _agentSummary != null;

        if (!keepSpecificLine)
            _agentSummary = report.Summary.Length > 0 ? report.Summary : null;

        RefreshAgentClock();

        if (report.Path is { Length: > 0 } path)
            AgentTouchedFile?.Invoke(this, path);
    }

    private readonly DispatcherQueue? _dispatcher;
    private DispatcherQueueTimer? _clock;

    /// <summary>The report's own words, without the elapsed time on the end.</summary>
    private string? _agentSummary;

    /// <summary>When the current turn began, and when the current state began.
    /// Two marks because they answer different questions.</summary>
    private DateTime _turnStart;
    private DateTime _stateSince;

    /// <summary>
    /// Puts the elapsed time on the end of the status line, and keeps it moving.
    ///
    /// Which span is shown depends on what the agent is doing, because the
    /// useful number is different in each case. While it works, the question is
    /// how long the turn has been going. While it is blocked, the question is
    /// how long it has been sitting there waiting for you. When it finishes,
    /// the question is how long the whole thing took.
    /// </summary>
    private void RefreshAgentClock()
    {
        if (_agentSummary == null)
        {
            StopClock();
            SetAgentStatus(null);
            return;
        }

        string? elapsed = ElapsedLabel();
        SetAgentStatus(elapsed == null ? _agentSummary : $"{_agentSummary} · {elapsed}");

        // "Done" is a finished measurement, so it stops rather than counting
        // on. A blocked agent keeps counting: the number growing is the point.
        bool moving = _lastEvent is AgentEvent.Prompt or AgentEvent.Tool or AgentEvent.Working
            or AgentEvent.Permission or AgentEvent.Idle or AgentEvent.Error;
        if (moving)
            StartClock();
        else
            StopClock();
    }

    private string? ElapsedLabel()
    {
        DateTime from = _lastEvent switch
        {
            // Measured from the prompt, through however many tools it took.
            AgentEvent.Prompt or AgentEvent.Tool
                or AgentEvent.Working or AgentEvent.Done => _turnStart,

            // Measured from the moment it stopped being able to continue.
            AgentEvent.Permission or AgentEvent.Idle or AgentEvent.Error => _stateSince,

            // "Ready" has nothing to measure yet.
            _ => default,
        };

        // No prompt seen: Zharp can start in the middle of somebody else's
        // turn. Falling back to this state's own start beats reporting the
        // time since the epoch.
        if (from == default)
            from = _lastEvent is AgentEvent.Start ? default : _stateSince;
        if (from == default)
            return null;

        return Format(DateTime.UtcNow - from);
    }

    /// <summary>
    /// Short enough for a tab card, and stable in width as it counts: the
    /// seconds are padded so the text does not shuffle every tick.
    /// </summary>
    private static string Format(TimeSpan span)
    {
        if (span < TimeSpan.Zero)
            span = TimeSpan.Zero;
        if (span.TotalMinutes < 1)
            return $"{span.Seconds}s";
        if (span.TotalHours < 1)
            return $"{span.Minutes}m {span.Seconds:00}s";
        return $"{(int)span.TotalHours}h {span.Minutes:00}m";
    }

    private void StartClock()
    {
        if (_clock == null)
        {
            if (_dispatcher == null)
                return;
            _clock = _dispatcher.CreateTimer();
            _clock.Interval = TimeSpan.FromSeconds(1);
            _clock.IsRepeating = true;
            _clock.Tick += (_, _) => RefreshAgentClock();
        }
        if (!_clock.IsRunning)
            _clock.Start();
    }

    private void StopClock() => _clock?.Stop();

    /// <summary>
    /// The tab is closing. Stops the clock and lets go of the spool, which is
    /// process wide and would otherwise hold every tab ever opened.
    /// </summary>
    public void StopAgentClock()
    {
        StopClock();
        if (_spoolHandler != null)
            AgentSpool.Reported -= _spoolHandler;
    }

    private static int IndexOfAgent(string name)
    {
        for (int i = 0; i < KnownAgents.Length; i++)
        {
            if (string.Equals(name, KnownAgents[i].Match, StringComparison.OrdinalIgnoreCase))
                return i;
        }
        return -1;
    }

    private long _lastStatusScrape;
    private bool _agentWasBusy;
    private AgentEvent? _lastEvent;

    private static readonly Color DoneGreen = Color.FromArgb(0xFF, 0x3F, 0xB9, 0x50);
    private static readonly Color NoTint = Color.FromArgb(0x00, 0x00, 0x00, 0x00);

    // Amber has to carry on both a near-black and a cream background, and one
    // value cannot: the bright gold that reads as a warning on dark is barely
    // legible on paper. So there are two, matching the badge dot's brushes.
    private static readonly Color WaitingAmberDark = Color.FromArgb(0xFF, 0xF0, 0xB4, 0x29);
    private static readonly Color WaitingAmberLight = Color.FromArgb(0xFF, 0xB0, 0x69, 0x00);

    /// <summary>Which theme the cards are drawn on. Process wide, like the
    /// setting behind it; the tint is a raw color, so it cannot ask XAML.</summary>
    internal static bool IsDarkTheme { get; set; } = true;

    /// <summary>
    /// Status line color: amber while the agent is waiting on you, green when
    /// it has finished, otherwise the theme's own. Transparent means untinted.
    /// </summary>
    public Color SubtitleTint
    {
        get
        {
            if (_needsAttention)
                return IsDarkTheme ? WaitingAmberDark : WaitingAmberLight;
            if (_lastEvent == AgentEvent.Done || _agentStatus == DoneStatus)
                return DoneGreen;
            return NoTint;
        }
    }

    /// <summary>
    /// Bold only while the agent is blocked. The status line is glanced at, not
    /// read, so the one state that wants you to act is the one state that gets
    /// weight; making the rest bold would spend the emphasis on nothing.
    /// </summary>
    public bool SubtitleBold => _needsAttention;

    /// <summary>
    /// The second line is normally held back so the first one leads. A blocked
    /// agent is the exception: dimming the one line that is asking for
    /// something was undoing the colour that was meant to make it stand out.
    /// </summary>
    public double SubtitleOpacity => _needsAttention ? 1.0 : 0.55;

    /// <summary>The theme changed under us, so the tint has to be re-read.</summary>
    public void ThemeChanged() => Notify(nameof(SubtitleTint));

    private void ApplyAgentStatus(string? spinner)
    {
        string? next;
        if (spinner != null)
        {
            _agentWasBusy = true;
            next = spinner;
        }
        else
        {
            // Spinner gone after a busy period = the agent finished a task.
            next = _agentWasBusy ? DoneStatus : null;
        }
        SetAgentStatus(next);
    }

    private void SetAgentStatus(string? status)
    {
        if (_agentStatus == status)
            return;
        _agentStatus = status;
        Notify(nameof(DisplaySubtitle));
        Notify(nameof(SubtitleTailFirst));
        Notify(nameof(SubtitleVisibility));
        Notify(nameof(SubtitleTint));
    }

    // Spinner frames used by agent CLIs (Claude Code's asterisk family and
    // friends). A status row starts with one of these and contains "…".
    private const string SpinnerGlyphs = "·✢✳✶✻✽✦✧∗✱*+";

    private static string? ScrapeAgentStatus(TerminalEmulator emu)
    {
        lock (emu.SyncRoot)
        {
            var buffer = emu.Buffer;
            int total = buffer.TotalLines;
            int screenTop = Math.Max(0, total - emu.Rows);
            for (int abs = total - 1; abs >= screenTop; abs--)
            {
                string line = LineText(buffer, abs);
                if (line.Length < 3 || SpinnerGlyphs.IndexOf(line[0]) < 0)
                    continue;
                if (!line.Contains('…'))
                    continue;
                return line.Length > 70 ? line[..70] : line;
            }
        }
        return null;
    }

    private static string LineText(ScreenBuffer buffer, int abs)
    {
        var line = buffer.GetAbsoluteLine(abs);
        var sb = new StringBuilder();
        foreach (ref readonly var cell in line.Cells.AsSpan())
        {
            if ((cell.Flags & CellFlags.WideTrailing) != 0)
                continue;
            sb.Append(cell.Rune == 0 ? " " : char.ConvertFromUtf32(cell.Rune));
        }
        return sb.ToString().Trim();
    }

    private bool SetAgent(int agent)
    {
        if (agent == _agent)
            return false;
        _agent = agent;
        if (agent >= 0)
        {
            AgentBrush.Color = KnownAgents[agent].Color;
        }
        else
        {
            // No agent: drop the live status entirely (including "Done").
            _agentWasBusy = false;
            _lastEvent = null;
            _agentSummary = null;
            _turnStart = default;
            StopClock();
            SetAgentStatus(null);

            // Reading the screen comes back for whatever runs next. Refusing to
            // fall back was about one agent's run, where a guess arriving after
            // a report would overrule it; across runs it would just mean that
            // starting an agent without hooks in this tab showed nothing at all.
            _reports = false;
        }
        Notify(nameof(StandardIconVisibility));
        Notify(nameof(ClaudeIconVisibility));
        Notify(nameof(AgentGlyph));
        return true;
    }

    /// <summary>Agent launched directly: the command's first token (or the
    /// second, for launchers like npx) is the agent binary's name.</summary>
    private static int DetectAgentFromCommand(string command)
    {
        string[] tokens = command.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (int t = 0; t < Math.Min(2, tokens.Length); t++)
        {
            string name;
            try
            {
                name = Path.GetFileNameWithoutExtension(tokens[t].Trim('"', '\'', '&'));
            }
            catch (ArgumentException)
            {
                continue;
            }
            for (int i = 0; i < KnownAgents.Length; i++)
            {
                if (string.Equals(name, KnownAgents[i].Match, StringComparison.OrdinalIgnoreCase))
                    return i;
            }
        }
        return -1;
    }

    private static int DetectAgent(string? title)
    {
        if (string.IsNullOrEmpty(title))
            return -1;
        for (int i = 0; i < KnownAgents.Length; i++)
        {
            if (title.Contains(KnownAgents[i].Match, StringComparison.OrdinalIgnoreCase))
                return i;
        }
        return -1;
    }

    /// <summary>Creates an embedded-page tab (e.g. Settings).</summary>
    public SessionItem(FrameworkElement content, string title, string subtitle, string iconGlyph)
    {
        Content = content;
        Title = title;
        _subtitle = subtitle;
        IconGlyph = iconGlyph;
    }

    // Zoom-scaled sizes for the card/pill templates (chrome zoom without
    // transforms - the templates bind these instead of hardcoding numbers).
    public double Z11 => 11 * _zoom;
    public double Z12 => 12 * _zoom;
    public double Z13 => 13 * _zoom;
    public double Z14 => 14 * _zoom;
    public double Z15 => 15 * _zoom;
    public double Z16 => 16 * _zoom;
    public double Z20 => 20 * _zoom;
    public double Z24 => 24 * _zoom;
    public double Z26 => 26 * _zoom;
    /// <summary>Search-palette path column width.</summary>
    public double Z170 => 170 * _zoom;

    /// <summary>Chrome zoom factor for the card sizes.</summary>
    public void SetUiZoom(double zoom)
    {
        if (Math.Abs(_zoom - zoom) < 0.001)
            return;
        _zoom = zoom;
        Notify(nameof(Z11));
        Notify(nameof(Z12));
        Notify(nameof(Z13));
        Notify(nameof(Z14));
        Notify(nameof(Z15));
        Notify(nameof(Z16));
        Notify(nameof(Z20));
        Notify(nameof(Z24));
        Notify(nameof(Z26));
        Notify(nameof(Z170));
    }

    private double _dragOpacity = 1;

    /// <summary>
    /// Dimmed while this tab is being carried in a drag. It lives on the item
    /// rather than on its card: the tab lists recycle card containers as items
    /// move, so anything written straight onto a container ends up dimming
    /// whichever tab inherits it.
    /// </summary>
    public double DragOpacity
    {
        get => _dragOpacity;
        set
        {
            if (Math.Abs(_dragOpacity - value) < 0.001)
                return;
            _dragOpacity = value;
            Notify(nameof(DragOpacity));
        }
    }

    /// <summary>Applies the sidebar display settings (title mode, path visibility).</summary>
    public void ApplyDisplayOptions(bool titleIsCwd, bool showPath)
    {
        if (_titleIsCwd == titleIsCwd && _showPath == showPath)
            return;
        _titleIsCwd = titleIsCwd;
        _showPath = showPath;
        Notify(nameof(SubtitleVisibility));
        NotifyDisplayChanged();
    }

    private void NotifyDisplayChanged()
    {
        Notify(nameof(Subtitle));
        Notify(nameof(DisplayTitle));
        Notify(nameof(DisplaySubtitle));
        Notify(nameof(CompactTitle));
        Notify(nameof(SessionName));
        Notify(nameof(KindLabel));
        Notify(nameof(TitleTailFirst));
        Notify(nameof(SubtitleTailFirst));
    }

    private void Notify(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public static string Abbreviate(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return "~";
        if (string.Equals(path, Home, StringComparison.OrdinalIgnoreCase))
            return "~";
        if (path.StartsWith(Home + "\\", StringComparison.OrdinalIgnoreCase))
            return "~" + path[Home.Length..];
        return path;
    }

    public override string ToString() => $"{DisplayTitle} · {DisplaySubtitle}";
}
