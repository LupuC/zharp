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
            if (_agent < 0)
                return;
            long now = Environment.TickCount64;
            if (now - _lastStatusScrape < 250)
                return;
            _lastStatusScrape = now;
            string? status = ScrapeAgentStatus(session.Emulator);
            dispatcher.TryEnqueue(() => ApplyAgentStatus(status));
        };
    }

    private long _lastStatusScrape;
    private bool _agentWasBusy;

    /// <summary>Green tint for the "Done" state; transparent = theme color.</summary>
    public Color SubtitleTint => _agentStatus == DoneStatus
        ? Color.FromArgb(0xFF, 0x3F, 0xB9, 0x50)
        : Color.FromArgb(0x00, 0x00, 0x00, 0x00);

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
            SetAgentStatus(null);
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
