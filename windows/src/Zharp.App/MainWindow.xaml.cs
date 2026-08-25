using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Graphics;
using Zharp.App.Controls;
using Zharp.Core.Terminal;

namespace Zharp.App;

public sealed partial class MainWindow : Window
{
    private readonly AppSettings _settings = App.Settings;
    private readonly ObservableCollection<SessionItem> _sessions = new();
    private readonly ObservableCollection<SessionItem> _visibleSessions = new();
    private SessionItem? _active;
    private SessionItem? _settingsItem;
    private SettingsView? _settingsView;
    private bool _suppressSelection;

    private const double MinSidebarWidth = 168;
    private bool _resizingSidebar;
    private double _splitterStartX;
    private double _splitterStartWidth;
    private Palette _terminalPalette = Palette.Cream();
    private readonly HashSet<(int Vk, InputModifiers Mods)> _reservedKeys = new();
    private readonly Dictionary<(int Vk, InputModifiers Mods), string> _blockBindings = new();
    private readonly CancellationTokenSource _updateCts = new();

    public MainWindow() : this(null)
    {
    }

    /// <summary>
    /// <paramref name="adopted"/> is a session dragged out of another window:
    /// this window opens around it instead of creating or restoring tabs.
    /// </summary>
    public MainWindow(SessionItem? adopted)
    {
        InitializeComponent();
        App.Windows.Add(this);
        StartDiffPolling();
        Activated += (_, _) => App.Main = this;

        Title = "Zharp";
        TrySetWindowIcon(this);
        AppWindow.Resize(new SizeInt32(1280, 800)); // backdrop set by ApplyTheme

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 480;
            presenter.PreferredMinimumHeight = 340;
            // Frameless: Zharp draws its own caption buttons so they can zoom
            // with the chrome (the system-drawn ones can never scale).
            presenter.SetBorderAndTitleBar(true, false);
        }

        SessionList.ItemsSource = _visibleSessions;
        SessionStrip.ItemsSource = _visibleSessions;
        // Clicking anywhere in the tab lists (including the already-active
        // card) returns keyboard focus to the terminal - otherwise the list
        // item keeps focus and typing goes nowhere.
        SessionList.Tapped += (_, _) => _active?.View?.FocusTerminal();
        SessionStrip.Tapped += (_, _) => _active?.View?.FocusTerminal();
        NewTabButtonSidebar.Flyout = BuildNewTabMenu();
        NewTabButtonStrip.Flyout = BuildNewTabMenu();
        EmptyStateNewTab.Flyout = BuildNewTabMenu();
        SidebarVersionText.Text = $"v{UpdateService.CurrentVersion}";

        ApplyTheme();
        RegisterAccelerators();
        ApplySidebarDisplay();
        ApplyTabLayout();
        Closed += OnWindowClosed;
        SizeChanged += (_, _) => ApplyUiZoom();
        // Keep the overlay terminal glued to the chrome's terminal area.
        // LayoutUpdated runs every pass; the sync is a cheap no-op when aligned.
        TerminalHost.SizeChanged += (_, _) => UpdateTerminalLayerLayout();
        TerminalHost.LayoutUpdated += (_, _) => UpdateTerminalLayerLayout();
        Root.Loaded += (_, _) =>
        {
            ApplyUiZoom();
            UpdateTitleBarPassthrough();
            // The compositor child windows exist only now - re-tint their
            // class brushes (the ctor pass could only reach the top level).
            SetWin32BackgroundBrush(_terminalPalette.DefaultBackground);
            if (Environment.GetEnvironmentVariable("ZHARP_TEST_ZOOM") == "1")
            {
                // Steps the UI zoom on a timer so the input harness can watch
                // overlay behavior across zoom changes without synthesizing
                // modifier state.
                int[] steps = [+1, +1, -1, -1, -1, +1];
                int at = 0;
                var zoomTimer = TestTimer(3, repeating: true);
                var start = TestTimer(15);
                start.Tick += (_, _) => zoomTimer.Start();
                start.Start();
                zoomTimer.Tick += (_, _) =>
                {
                    App.Log($"test-zoom step {at}: {steps[at]:+0;-0} -> zoom will be applied");
                    ChangeUiZoom(steps[at]);
                    if (++at >= steps.Length)
                        zoomTimer.Stop();
                };
            }
            if (Environment.GetEnvironmentVariable("ZHARP_TEST_GHOST") == "1")
            {
                // Parks the drag preview on screen so its look can be checked
                // without holding a drag.
                var show = TestTimer(3);
                show.Tick += (_, _) =>
                {
                    var item = _sessions.FirstOrDefault(s => !s.IsSettings);
                    if (item == null)
                        return;
                    _cardSize = new Size(200, 44);
                    ShowGhost(item);
                    var centre = new PointInt32(
                        AppWindow.Position.X + AppWindow.Size.Width / 2,
                        AppWindow.Position.Y + AppWindow.Size.Height / 2);
                    MoveGhost(centre);
                    // The drop hit-test must resolve to THIS window. With the
                    // preview still up it finds the preview instead, which is
                    // what made every drop read as "outside".
                    App.Log($"ghost-test: preview up   -> {Describe(WindowAt(centre))}");
                    ClearDragState();
                    App.Log($"ghost-test: preview gone -> {Describe(WindowAt(centre))} (expect self)");

                    string Describe(MainWindow? w) =>
                        w == null ? "outside" : ReferenceEquals(w, this) ? "self" : "other";
                };
                show.Start();
            }
            // Torn-off windows must not arm it again, or each new window would
            // tear off another tab in turn.
            if (adopted == null && Environment.GetEnvironmentVariable("ZHARP_TEST_TEAROFF") == "1")
            {
                // Moves a live tab into a second window on a timer, so the
                // hand-off can be checked without synthesizing a drag.
                App.Log($"test-tearoff: armed, sessions={_sessions.Count}");
                var arm = TestTimer(5);
                arm.Tick += (_, _) =>
                {
                    if (_sessions.Count < 2)
                        AddTab();
                    var fire = TestTimer(4);
                    fire.Tick += (_, _) =>
                    {
                        var item = _sessions.LastOrDefault(s => !s.IsSettings);
                        if (item == null || _sessions.Count < 2)
                        {
                            App.Log($"test-tearoff: skipped, sessions={_sessions.Count}");
                            return;
                        }
                        App.Log($"test-tearoff: '{item.DisplayTitle}' -> new window");
                        ReleaseSession(item);
                        OpenWindowFor(item,
                            new PointInt32(AppWindow.Position.X + 300, AppWindow.Position.Y + 240));
                    };
                    fire.Start();
                };
                arm.Start();
            }
            if (Environment.GetEnvironmentVariable("ZHARP_TEST_SETTINGS") == "1")
            {
                var timer = TestTimer(5);
                timer.Tick += (_, _) =>
                {
                    OpenSettings();
                    var t2 = TestTimer(2);
                    t2.Tick += (_, _) => _settingsView?.ScrollToEnd();
                    t2.Start();
                };
                timer.Start();
            }
        };

        if (adopted != null)
            AdoptSession(adopted);
        else
            RestoreOrAddTab();

        // Onboarding and the update watcher belong to the session as a whole,
        // not to each window: torn-off windows skip both.
        if (adopted == null && !_settings.Onboarded)
            ShowOnboarding();

        if (Interlocked.Exchange(ref _updateWatcher, 1) == 0)
        {
            _ownsUpdateWatcher = true;
            _ = NotifyOnUpdateAsync();
        }
        else if (App.Windows.FirstOrDefault(w =>
                     !ReferenceEquals(w, this) && w._updateAvailable != null) is { } informed)
        {
            // A window opened between hourly checks still has to show the badge.
            ShowUpdateBadge(informed._updateAvailable);
        }
    }

    /// <summary>1 once some window is running the hourly update check.</summary>
    private static int _updateWatcher;
    private bool _ownsUpdateWatcher;

    /// <summary>Keeps the ZHARP_TEST_* timers alive: a DispatcherQueueTimer held
    /// only in a local can be collected before it ever ticks.</summary>
    private readonly List<Microsoft.UI.Dispatching.DispatcherQueueTimer> _testTimers = new();

    private Microsoft.UI.Dispatching.DispatcherQueueTimer TestTimer(double seconds, bool repeating = false)
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(seconds);
        timer.IsRepeating = repeating;
        _testTimers.Add(timer);
        return timer;
    }

    /// <summary>Background update checks: shortly after launch, then hourly
    /// while the window stays open. Toasts once per new version.</summary>
    private async Task NotifyOnUpdateAsync()
    {
        var delay = TimeSpan.FromSeconds(15);
        while (!_updateCts.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(delay, _updateCts.Token);
                delay = TimeSpan.FromHours(1);

                var latest = await UpdateService.GetLatestAsync(_settings.UpdateBaseUrl);
                if (Environment.GetEnvironmentVariable("ZHARP_FAKE_UPDATE") == "1")
                    latest = new Version(9, 9, 9); // test hook: badge + toast without a real release
                if (latest == null)
                    continue; // unreachable server: keep the last known state

                // Title-bar badge follows every check; the toast fires once.
                // One window runs the check, every window shows the result.
                var available = latest > UpdateService.CurrentVersion ? latest : null;
                foreach (var window in App.Windows.ToList())
                    window.ShowUpdateBadge(available);

                if (available == null)
                    continue;
                if (_settings.LastNotifiedUpdate == latest.ToString())
                    continue;

                var notification = new Microsoft.Windows.AppNotifications.Builder.AppNotificationBuilder()
                    .AddText("Zharp update available")
                    .AddText($"Version {latest} is ready to install - you have {UpdateService.CurrentVersion}.")
                    .AddButton(new Microsoft.Windows.AppNotifications.Builder.AppNotificationButton("Open updater")
                        .AddArgument("action", "update"))
                    .BuildNotification();
                Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Show(notification);

                // Recorded only after Show, so a failed toast retries next check.
                _settings.LastNotifiedUpdate = latest.ToString();
                _settings.Save();
            }
            catch (OperationCanceledException)
            {
                return; // window closed
            }
            catch (Exception ex)
            {
                App.Log("Update notification failed: " + ex);
            }
        }
    }

    private Version? _updateAvailable;

    /// <summary>Picks up the hourly update check when its owner window closes.</summary>
    internal void TakeOverUpdateWatch()
    {
        if (_updateCts.IsCancellationRequested)
            return;
        if (Interlocked.Exchange(ref _updateWatcher, 1) == 0)
        {
            _ownsUpdateWatcher = true;
            _ = NotifyOnUpdateAsync();
        }
    }

    /// <summary>Shows or hides this window's update badge.</summary>
    internal void ShowUpdateBadge(Version? available)
    {
        _updateAvailable = available;
        UpdateBadge.Visibility = available != null ? Visibility.Visible : Visibility.Collapsed;
        if (available != null)
            ToolTipService.SetToolTip(UpdateBadge, $"Zharp {available} is ready to install");
        UpdateTitleBarPassthrough();
    }

    /// <summary>Brings the window up and opens Settings on the About page,
    /// with the update button pre-armed (badge + toast click target).</summary>
    public void ShowUpdatePage()
    {
        Activate();
        OpenSettings();
        _settingsView?.ShowAbout();
        if (_updateAvailable != null)
            _settingsView?.PrepareUpdate(_updateAvailable);
    }

    private void OnUpdateBadgeClick(object sender, RoutedEventArgs e) => ShowUpdatePage();

    private void ShowOnboarding()
    {
        var onboarding = new OnboardingView(_settings)
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        onboarding.Changed += OnSettingsChanged;
        onboarding.Finished += () =>
        {
            _active?.View?.FocusTerminal(); // focus-first, then remove
            OnboardingOverlay.Visibility = Visibility.Collapsed;
            OnboardingOverlay.Children.Clear();
        };
        OnboardingOverlay.Children.Add(onboarding);
        OnboardingOverlay.Visibility = Visibility.Visible;
    }

    // ---------------------------------------------------------------- sessions

    /// <summary>Startup tabs: the previous run's sessions when restore is on
    /// and a snapshot exists, otherwise a single default terminal.</summary>
    private void RestoreOrAddTab()
    {
        if (_settings.RestoreSessions && _settings.SavedSessions.Count > 0)
        {
            foreach (var saved in _settings.SavedSessions)
            {
                // A vanished directory falls back to the default start folder.
                string? dir = saved.Directory.Length > 0 && Directory.Exists(saved.Directory)
                    ? saved.Directory : null;
                AddTab(saved.Shell.Length > 0 ? saved.Shell : null, dir);
            }
            ActivateSession(_sessions[Math.Clamp(_settings.SavedActiveIndex, 0, _sessions.Count - 1)]);
            return;
        }
        AddTab();
    }

    /// <summary>New terminal tab. Null shell = the configured default shell;
    /// null directory = the configured default directory.</summary>
    private void AddTab(string? shellId = null, string? startDirectory = null)
    {
        var shell = ShellDiscovery.GetShell(shellId ?? _settings.Shell);
        string startDir = startDirectory ?? ResolveDefaultDirectory();

        var session = new TerminalSession(shell.CommandLine, startDir, shell.DisplayName, _settings.ScrollbackLines)
        {
            OverrideNoColor = _settings.OverrideNoColor,
            ExtraEnvironment = shell.ExtraEnvironment,
        };
        ShowCodexTrustNotice(session);

        var view = new TerminalView(session, _settings.FontSize, _settings.FontFamily)
        {
            DefaultCursorStyleCode = AppSettings.CursorStyleToCode(_settings.CursorStyle),
        };
        view.SetPalette(_terminalPalette);
        view.SetUiZoom(_settings.UiZoom);
        view.SetInputPosition(AppSettings.InputPositionToCode(_settings.InputPosition));
        view.IsReservedShortcut = (vk, mods) => _reservedKeys.Contains((vk, mods));
        view.ResolveBlockShortcut = (vk, mods) =>
            _blockBindings.TryGetValue((vk, mods), out string? actionId) ? actionId : null;
        view.BlockShortcutText = actionId => Shortcuts.GetBinding(_settings, actionId);
        var item = new SessionItem(session, view, shell.DisplayName, DispatcherQueue, shellId);

        // cd'ing into or out of a repository decides whether the title bar
        // carries a diff button at all, so the button follows the prompt.
        // Location rather than directory: typing `ssh` changes which machine
        // the question is about without the local directory moving at all.
        session.LocationChanged += _ =>
            DispatcherQueue.TryEnqueue(UpdateDiffButtonAsync);
        item.ApplyDisplayOptions(_settings.SidebarTitleIsCwd, _settings.SidebarShowPath);
        item.SetUiZoom(_settings.UiZoom);

        session.CommandExecuted += cmd =>
            HistoryStore.Instance.Add(cmd, session.WorkingDirectory, shell.DisplayName);

        // Both of these resolve the owning window when they fire rather than
        // closing over this one. A tab can be dragged into another window with
        // its shell still running, and the badge, the taskbar and the changes
        // panel all belong to whichever window is holding it at the time.
        item.AttentionChanged += owner =>
            OwnerOf(owner)?.OnSessionAttentionChanged(owner);

        // The agent says which file it just wrote; the panel is what shows it.
        item.AgentTouchedFile += (owner, path) =>
            OwnerOf(owner)?.FollowAgentEdit(owner, path);

        HookSessionToWindow(item);

        _sessions.Add(item);
        RefreshVisibleSessions();
        ActivateSession(item);
    }

    /// <summary>
    /// Explains, once, that Codex is about to ask whether to trust the hooks
    /// Zharp just wrote.
    ///
    /// Codex will not run a hook it has not been told to trust, and that is a
    /// good rule, exactly because a program writing hooks into your agent is
    /// the case it guards. Zharp does not try to route around it. But a Codex
    /// tab that reports nothing looks broken rather than unapproved, so the
    /// user is told what to expect.
    ///
    /// Written into the emulator before the shell starts, while the screen is
    /// still empty. Feeding it later would land in the middle of a prompt line
    /// and corrupt it.
    /// </summary>
    private void ShowCodexTrustNotice(TerminalSession session)
    {
        if (!_settings.AgentIntegration)
            return;
        if (_settings.CodexNoticeFor == CodexIntegration.ScriptPath)
            return;
        if (!CodexIntegration.IsConnected())
            return;

        session.Emulator.Feed(System.Text.Encoding.UTF8.GetBytes(
            "\x1b[2mZharp installed status hooks for Codex. "
            + "Codex will ask you to trust them the next time it starts.\x1b[0m\r\n"));

        _settings.CodexNoticeFor = CodexIntegration.ScriptPath;
        _settings.Save();
    }

    /// <summary>Whichever window is currently holding this tab.</summary>
    private static MainWindow? OwnerOf(SessionItem item) =>
        App.Windows.FirstOrDefault(w => w._sessions.Contains(item));

    /// <summary>
    /// Opens the file the agent just wrote, when this tab is the one on screen
    /// and its changes panel is open. Following a file in a tab you cannot see
    /// would move the panel out from under whatever you are actually reading.
    /// </summary>
    private void FollowAgentEdit(SessionItem item, string path)
    {
        if (!ReferenceEquals(_active, item) || _diffView == null)
            return;
        if (DiffPanel.Visibility != Visibility.Visible)
            return;
        _ = _diffView.FollowAsync(path);
    }

    /// <summary>
    /// An agent in one of this window's tabs has become blocked on the user.
    ///
    /// The tab card carries a badge for itself. This is about the case the
    /// badge cannot cover: the tab is not the one on screen, or Zharp is not
    /// the window you are looking at. Then it is worth saying so out loud,
    /// because the whole point of running several agents is not watching them.
    /// </summary>
    private void OnSessionAttentionChanged(SessionItem item)
    {
        if (!item.NeedsAttention)
            return;

        // Already in front of them. The status line says the rest.
        bool visible = ReferenceEquals(_active, item) && IsForeground();
        if (visible)
        {
            item.MarkSeen();
            return;
        }

        // The tab always carries its badge. This is only about reaching you
        // somewhere else, which is exactly the part worth being able to switch
        // off, so it is the only part the setting governs.
        if (!_settings.AgentNotifications)
            return;

        FlashTaskbar();

        try
        {
            var toast = new Microsoft.Windows.AppNotifications.Builder.AppNotificationBuilder()
                .AddText($"{item.SessionName} needs you")
                .AddText($"{item.DisplaySubtitle} - {item.Subtitle}")
                // Tagged so the click lands on this session. Without it every
                // notification Zharp raises went to the same handler, and an
                // agent asking a question opened the update page.
                .AddArgument("action", "agent")
                .AddArgument("session", item.Id.ToString())
                .BuildNotification();
            Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Show(toast);
            App.Log($"agent toast: {item.SessionName} - {item.DisplaySubtitle}");
        }
        catch (Exception ex)
        {
            // A toast is a courtesy. The badge and the taskbar already said it.
            App.Log($"agent toast failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Brings up the session a notification was raised for. The tab may have
    /// been dragged to another window, or closed outright, since the toast was
    /// shown, so the session is looked up rather than remembered.
    /// </summary>
    internal static void ShowAgentSession(int id)
    {
        foreach (var window in App.Windows.ToList())
        {
            var item = window._sessions.FirstOrDefault(s => s.Id == id);
            if (item == null)
                continue;
            window.Activate();
            window.ActivateSession(item);
            return;
        }
    }

    private bool IsForeground() =>
        GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(this);

    /// <summary>
    /// The conventional Windows "over here" - the taskbar button flashes until
    /// the window is brought forward, and stays highlighted after it stops.
    /// Deliberately not a window that steals focus: the user is in the middle
    /// of something, and an agent waiting is not an emergency.
    /// </summary>
    private void FlashTaskbar()
    {
        try
        {
            var info = new FLASHWINFO
            {
                cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<FLASHWINFO>(),
                hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this),
                dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG,
                uCount = 3,
                dwTimeout = 0,
            };
            FlashWindowEx(ref info);
        }
        catch (Exception ex)
        {
            App.Log($"agent flash: {ex.Message}");
        }
    }

    private const uint FLASHW_TRAY = 0x00000002;
    private const uint FLASHW_TIMERNOFG = 0x0000000C;

    [System.Runtime.InteropServices.StructLayout(
        System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    /// <summary>Points the session's window-scoped wiring at THIS window. A tab
    /// carries its shell between windows, so the handler that closes the tab on
    /// exit has to follow it - otherwise the shell would exit and the tab would
    /// linger in a window that no longer owns it.</summary>
    private void HookSessionToWindow(SessionItem item)
    {
        if (item.Session is not { } session || item.View is not { } view)
            return;

        if (item.ExitHandler != null)
            session.Exited -= item.ExitHandler;
        // Resolves the owner when the shell actually exits rather than closing
        // over this window: an exit racing a hand-over would otherwise be
        // delivered to the window that no longer holds the tab, leaving a dead
        // shell sitting in the new one.
        item.ExitHandler = _ => DispatcherQueue.TryEnqueue(() =>
            App.Windows.FirstOrDefault(w => w._sessions.Contains(item))?.CloseTab(item));
        session.Exited += item.ExitHandler;

        view.IsReservedShortcut = (vk, mods) => _reservedKeys.Contains((vk, mods));
        view.ResolveBlockShortcut = (vk, mods) =>
            _blockBindings.TryGetValue((vk, mods), out string? actionId) ? actionId : null;
        view.BlockShortcutText = actionId => Shortcuts.GetBinding(_settings, actionId);
    }

    /// <summary>Takes a session dragged in from another window.</summary>
    internal void AdoptSession(SessionItem item)
    {
        HookSessionToWindow(item);
        item.View!.SetPalette(_terminalPalette);
        item.View.SetUiZoom(_settings.UiZoom);
        item.SetUiZoom(_settings.UiZoom);
        item.ApplyDisplayOptions(_settings.SidebarTitleIsCwd, _settings.SidebarShowPath);

        _sessions.Add(item);
        RefreshVisibleSessions();
        ActivateSession(item);
    }

    /// <summary>Releases a session WITHOUT tearing down its shell, so another
    /// window can take it over. The mirror image of <see cref="AdoptSession"/>.</summary>
    private void ReleaseSession(SessionItem item)
    {
        int index = _sessions.IndexOf(item);
        if (index < 0)
            return;

        CloseOpenSessionTip();
        if (item.ExitHandler != null && item.Session != null)
        {
            item.Session.Exited -= item.ExitHandler;
            item.ExitHandler = null;
        }
        if (item.View != null)
            TerminalLayer.Children.Remove(item.View);

        _sessions.RemoveAt(index);
        RefreshVisibleSessions();

        if (!ReferenceEquals(_active, item))
            return;
        _active = null;
        if (_sessions.Count > 0)
            ActivateSession(_sessions[Math.Min(index, _sessions.Count - 1)]);
        else
            ShowEmptyState();
    }

    private string ResolveDefaultDirectory() =>
        !string.IsNullOrWhiteSpace(_settings.DefaultDirectory) && Directory.Exists(_settings.DefaultDirectory)
            ? _settings.DefaultDirectory
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    private string ResolveLastLocation()
    {
        if (!string.IsNullOrWhiteSpace(_settings.LastClosedDirectory) &&
            Directory.Exists(_settings.LastClosedDirectory))
        {
            return _settings.LastClosedDirectory;
        }
        string? activeDir = _active?.Session?.WorkingDirectory;
        return activeDir != null && Directory.Exists(activeDir) ? activeDir : ResolveDefaultDirectory();
    }

    private MenuFlyout BuildNewTabMenu()
    {
        var menu = new MenuFlyout
        {
            // Centered under the button (edge-aligned looks lopsided,
            // especially on the empty-state button).
            Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Bottom,
        };
        AddEntry("Terminal", "", () => AddTab(),
            Shortcuts.GetBinding(_settings, "newTab"));
        AddEntry("Terminal at last location", "", () => AddTab(null, ResolveLastLocation()));
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var (id, name) in ShellDiscovery.GetAvailableShells())
        {
            string shellId = id;
            AddEntry(name, ShellGlyph(shellId), () => AddTab(shellId));
        }
        return menu;

        void AddEntry(string text, string glyph, Action action, string? accelerator = null)
        {
            var entry = new MenuFlyoutItem
            {
                Text = text,
                FontSize = 12,
                Icon = new FontIcon
                {
                    FontFamily = (FontFamily)Application.Current.Resources["TablerIcons"],
                    Glyph = glyph,
                    FontSize = 16,
                },
            };
            if (accelerator != null)
                entry.KeyboardAcceleratorTextOverride = accelerator;
            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }
    }

    private static string ShellGlyph(string shellId) => shellId switch
    {
        "pwsh" or "powershell" => "", // brand-powershell
        "cmd" => "",                  // prompt
        "gitbash" => "",              // brand-git
        "wsl" => "",                  // brand-ubuntu
        _ => "",                      // terminal
    };

    private void CloseTab(SessionItem item)
    {
        CloseOpenSessionTip(); // the hovered card is about to disappear
        int index = _sessions.IndexOf(item);
        if (index < 0)
            return;

        if (!item.IsSettings && item.Session?.WorkingDirectory is { Length: > 0 } lastDir)
        {
            _settings.LastClosedDirectory = lastDir;
            _settings.Save();
        }

        if (item.IsSettings)
        {
            // The settings view is kept cached; the tab just goes away.
            _settingsItem = null;
        }
        else
        {
            item.StopAgentClock();
            item.View!.Dispose();
            item.Session!.Dispose();
        }
        _sessions.RemoveAt(index);

        if (_sessions.Count == 0)
        {
            RefreshVisibleSessions();
            ShowEmptyState();
            return;
        }

        RefreshVisibleSessions();
        if (_active == item)
            ActivateSession(_sessions[Math.Min(index, _sessions.Count - 1)]);
    }

    /// <summary>All tabs are gone: keep the app open on a placeholder page.</summary>
    private void ShowEmptyState()
    {
        _active = null;
        EmptyState.Visibility = Visibility.Visible;
        EmptyStateNewTab.Focus(FocusState.Programmatic); // focus-first...
        TerminalLayer.Children.Clear();                  // ...remove-after
        TerminalHost.Content = null;

        _suppressSelection = true;
        SessionList.SelectedItem = null;
        SessionStrip.SelectedItem = null;
        _suppressSelection = false;
    }

    /// <summary>Drops every terminal view from the overlay layer except the
    /// active one - stale siblings from interrupted swaps sit on top and eat
    /// pointer input.</summary>
    private void RemoveStaleTerminalViews()
    {
        var stale = TerminalLayer.Children
            .Where(c => !ReferenceEquals(c, _active?.View))
            .ToList();
        foreach (var view in stale)
            TerminalLayer.Children.Remove(view);
        UpdateTerminalLayerLayout();
    }

    private void ActivateSession(SessionItem item)
    {
        _active = item;

        // Looking at the tab is what clears its badge. Whatever the agent
        // wants is now on screen in front of you.
        item.MarkSeen();

        // Every transition is focus-first, remove-after: if the focused element
        // leaves the tree first, XAML bounces focus to the first tab stop (the
        // sidebar toggle button flashes its focus ring + tooltip).
        if (item.View != null)
        {
            if (!TerminalLayer.Children.Contains(item.View))
            {
                var view = item.View;
                view.RenderTransform = null;
                TerminalLayer.Children.Add(view);
                UpdateTerminalLayerLayout(); // position immediately, no stretch flash
                RoutedEventHandler? once = null;
                once = (_, _) =>
                {
                    view.Loaded -= once;
                    // The user may have switched again before this view loaded:
                    // act on the CURRENT active view, never on a stale capture.
                    // (Removing the active view here used to orphan a dead view
                    // on top of the layer - unclickable terminal until the next
                    // tab switch.)
                    if (ReferenceEquals(_active?.View, view))
                    {
                        view.FocusTerminal();
                        EmptyState.Visibility = Visibility.Collapsed; // after focus moved
                        TerminalHost.Content = null; // settings page may leave now
                    }
                    RemoveStaleTerminalViews();
                };
                view.Loaded += once;
            }
            else
            {
                item.View.FocusTerminal();
                EmptyState.Visibility = Visibility.Collapsed;
                TerminalHost.Content = null;
                // Already loaded: any sibling left from an in-flight swap is
                // stale and would sit on top, eating input.
                RemoveStaleTerminalViews();
            }
        }
        else if (!ReferenceEquals(TerminalHost.Content, item.Content))
        {
            var page = (FrameworkElement)item.Content;
            RoutedEventHandler? once = null;
            once = (_, _) =>
            {
                page.Loaded -= once;
                if (ReferenceEquals(_active, item))
                {
                    (page as SettingsView)?.FocusFirst();
                    EmptyState.Visibility = Visibility.Collapsed; // after focus moved
                    TerminalLayer.Children.Clear(); // terminal may leave now
                }
                else
                {
                    // Switched away before the page loaded: only sweep views
                    // that are not the currently active terminal.
                    RemoveStaleTerminalViews();
                }
            };
            page.Loaded += once;
            TerminalHost.Content = page;
        }

        _suppressSelection = true;
        SessionList.SelectedItem = _visibleSessions.Contains(item) ? item : null;
        SessionStrip.SelectedItem = SessionList.SelectedItem;
        _suppressSelection = false;

        ApplyDiffStateForActive();
        DispatcherQueue.TryEnqueue(UpdateTerminalLayerLayout);
        UpdateDiffButtonAsync();
    }

    /// <summary>
    /// Positions the overlay terminal (physical pixels, no transforms) exactly
    /// over the chrome's terminal area. TransformBounds includes the chrome's
    /// zoom scale, so the rect is already in screen DIPs.
    /// </summary>
    private void UpdateTerminalLayerLayout()
    {
        // Position the ACTIVE view (during a swap the outgoing sibling keeps
        // its stale rect until removal - no stretch flash).
        if (_active?.View is not TerminalView view || !TerminalLayer.Children.Contains(view))
            return;
        if (TerminalHost.ActualWidth <= 0 || TerminalHost.ActualHeight <= 0)
            return;

        Rect rect;
        try
        {
            rect = TerminalHost.TransformToVisual(OuterRoot)
                .TransformBounds(new Rect(0, 0, TerminalHost.ActualWidth, TerminalHost.ActualHeight));
        }
        catch
        {
            return;
        }

        bool inSync =
            Math.Abs(view.Margin.Left - rect.X) < 0.5 &&
            Math.Abs(view.Margin.Top - rect.Y) < 0.5 &&
            !double.IsNaN(view.Width) && Math.Abs(view.Width - rect.Width) < 0.5 &&
            !double.IsNaN(view.Height) && Math.Abs(view.Height - rect.Height) < 0.5;
        if (inSync)
            return; // runs on every LayoutUpdated - exit cheap when aligned

        view.HorizontalAlignment = HorizontalAlignment.Left;
        view.VerticalAlignment = VerticalAlignment.Top;
        view.Margin = new Thickness(rect.X, rect.Y, 0, 0);
        view.Width = rect.Width;
        view.Height = rect.Height;
    }

    private void CycleSession(int direction)
    {
        if (_sessions.Count < 2 || _active == null)
            return;
        int index = _sessions.IndexOf(_active);
        index = (index + direction + _sessions.Count) % _sessions.Count;
        ActivateSession(_sessions[index]);
    }

    private void RefreshVisibleSessions()
    {
        string filter = TabSearch.Text?.Trim() ?? "";
        var desired = _sessions.Where(s =>
            filter.Length == 0 ||
            s.Title.Contains(filter, StringComparison.OrdinalIgnoreCase) ||
            s.Subtitle.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();

        // Sync incrementally instead of Clear()+rebuild - a full reset would
        // re-realize every container and replay entrance animations (the whole
        // list visibly "reloads" when a tab is added or closed).
        for (int i = _visibleSessions.Count - 1; i >= 0; i--)
        {
            if (!desired.Contains(_visibleSessions[i]))
                _visibleSessions.RemoveAt(i);
        }
        for (int i = 0; i < desired.Count; i++)
        {
            int current = _visibleSessions.IndexOf(desired[i]);
            if (current < 0)
                _visibleSessions.Insert(Math.Min(i, _visibleSessions.Count), desired[i]);
            else if (current != i)
                _visibleSessions.Move(current, i);
        }

        _suppressSelection = true;
        SessionList.SelectedItem = _active != null && _visibleSessions.Contains(_active) ? _active : null;
        SessionStrip.SelectedItem = SessionList.SelectedItem;
        _suppressSelection = false;
    }

    // ---------------------------------------------------------------- tab layout

    private void ApplyTabLayout()
    {
        bool sidebar = _settings.UseSidebar;
        bool tabsVisible = _settings.SidebarVisible;
        bool sidebarShown = sidebar && tabsVisible;

        double zoom = _settings.UiZoom;
        SidebarHost.Visibility = sidebarShown ? Visibility.Visible : Visibility.Collapsed;
        SidebarResizer.Visibility = sidebarShown ? Visibility.Visible : Visibility.Collapsed;
        double width = Math.Clamp(_settings.SidebarWidth * zoom, MinSidebarWidth * zoom, MaxSidebarWidth());
        SidebarColumn.Width = sidebarShown ? new GridLength(width) : new GridLength(0);

        TopStripHost.Visibility = !sidebar && tabsVisible ? Visibility.Visible : Visibility.Collapsed;
        TopStripRow.Height = !sidebar && tabsVisible ? new GridLength(34 * zoom) : new GridLength(0);
    }

    // ---------------------------------------------------------------- sidebar resizing

    private double MaxSidebarWidth()
    {
        double rootWidth = Root.ActualWidth > 0 ? Root.ActualWidth : 1280;
        return Math.Max(MinSidebarWidth, rootWidth / 2);
    }

    private void ClampSidebarWidth()
    {
        if (SidebarColumn.Width.Value <= 0)
            return;
        double clamped = Math.Clamp(SidebarColumn.Width.Value,
            MinSidebarWidth * _settings.UiZoom, MaxSidebarWidth());
        if (Math.Abs(clamped - SidebarColumn.Width.Value) > 0.5)
            SidebarColumn.Width = new GridLength(clamped);
    }

    private void OnSplitterPressed(object sender, PointerRoutedEventArgs e)
    {
        _resizingSidebar = true;
        _splitterStartX = e.GetCurrentPoint(Root).Position.X;
        _splitterStartWidth = SidebarColumn.ActualWidth;
        ((UIElement)sender).CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnSplitterMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizingSidebar)
            return;
        double x = e.GetCurrentPoint(Root).Position.X;
        double width = Math.Clamp(_splitterStartWidth + (x - _splitterStartX),
            MinSidebarWidth * _settings.UiZoom, MaxSidebarWidth());
        SidebarColumn.Width = new GridLength(width);
        e.Handled = true;
    }

    private void OnSplitterReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizingSidebar)
            return;
        _resizingSidebar = false;
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);
        // Stored width is zoom-independent (logical).
        _settings.SidebarWidth = SidebarColumn.ActualWidth / _settings.UiZoom;
        _settings.Save();
        e.Handled = true;
    }

    private void OnSplitterCaptureLost(object sender, PointerRoutedEventArgs e) => _resizingSidebar = false;

    // ---------------------------------------------------------------- UI zoom

    private void ChangeUiZoom(int direction)
    {
        double zoom = direction == 0
            ? 1.0
            : Math.Round(Math.Clamp(_settings.UiZoom + direction * 0.1, 0.7, 1.5), 2);
        if (Math.Abs(zoom - _settings.UiZoom) < 0.001)
            return;
        _settings.UiZoom = zoom;
        _settings.Save();
        ApplyUiZoom();
    }

    /// <summary>
    /// Whole-UI zoom WITHOUT transforms: the chrome multiplies its real metrics
    /// (fonts, icons, control sizes via ChromeZoom + SessionItem bound sizes)
    /// so everything re-renders crisply; terminals zoom via their font size.
    /// </summary>
    private void ApplyUiZoom()
    {
        double zoom = _settings.UiZoom;

        TitleBarRow.Height = new GridLength(Math.Max(26, 32 * zoom));
        ChromeZoom.Apply(Root, zoom);
        _settingsView?.SetZoom(zoom);

        // The search palette is outside Root, so the ChromeZoom walker never
        // reaches it; its few metrics scale here (item fonts use Z-bindings).
        SearchPanel.Width = 460 * zoom;
        SearchBox.FontSize = 13 * zoom;
        SearchBox.MinHeight = 30 * zoom;
        SearchResults.MaxHeight = 280 * zoom;

        foreach (var item in _sessions)
        {
            item.View?.SetUiZoom(zoom);
            item.SetUiZoom(zoom);
        }

        ApplyTabLayout();
        ClampSidebarWidth();
        DispatcherQueue.TryEnqueue(() =>
        {
            UpdateTitleBarPassthrough();
            UpdateTerminalLayerLayout();
        });
    }

    private void ToggleSidebar()
    {
        _settings.SidebarVisible = !_settings.SidebarVisible;
        _settings.Save();
        ApplyTabLayout();
    }

    private void OnSidebarToggleClick(object sender, RoutedEventArgs e) => ToggleSidebar();

    /// <summary>Applies sidebar card density and content settings.</summary>
    private void ApplySidebarDisplay()
    {
        bool showSearch = _settings.SidebarShowSearch;
        TabSearch.Visibility = showSearch ? Visibility.Visible : Visibility.Collapsed;
        SessionsLabel.Visibility = showSearch ? Visibility.Collapsed : Visibility.Visible;
        if (!showSearch && !string.IsNullOrEmpty(TabSearch.Text))
            TabSearch.Text = "";

        string templateKey = _settings.SidebarCompact ? "SessionCardCompactTemplate" : "SessionCardTemplate";
        if (Root.Resources[templateKey] is DataTemplate template)
            SessionList.ItemTemplate = template;
        foreach (var item in _sessions)
            item.ApplyDisplayOptions(_settings.SidebarTitleIsCwd, _settings.SidebarShowPath);
    }

    private void OnSettingsClick(object sender, RoutedEventArgs e) => OpenSettings();

    private void OpenSettings()
    {
        try
        {
            if (_settingsItem == null)
            {
                if (_settingsView == null)
                {
                    _settingsView = new SettingsView(_settings);
                    _settingsView.Changed += OnSettingsChanged;
                    _settingsView.Loaded += (_, _) =>
                    {
                        ChromeZoom.Apply(_settingsView, _settings.UiZoom);
                        _settingsView.SetZoom(_settings.UiZoom);
                    };
                }
                _settingsItem = new SessionItem(_settingsView, "Settings", "Preferences", "\uEB20");
                _settingsItem.SetUiZoom(_settings.UiZoom);
                _sessions.Add(_settingsItem);
                RefreshVisibleSessions();
            }
            ActivateSession(_settingsItem);
        }
        catch (Exception ex)
        {
            App.Log($"Opening settings failed: {ex}");
        }
    }

    private void OnDiffClick(object sender, RoutedEventArgs e) => ToggleDiff();

    /// <summary>
    /// Shows or hides the changes panel beside the terminal.
    ///
    /// A split rather than a tab, because a diff is something you read WHILE
    /// working: as a session it replaced the terminal you were comparing it
    /// against, which is the one thing you wanted to keep looking at.
    ///
    /// The terminal needs no repositioning code here. It lives in TerminalLayer
    /// and is placed from TerminalHost's bounds on every LayoutUpdated, so
    /// narrowing the column moves it on its own.
    /// </summary>
    private void ToggleDiff()
    {
        if (DiffPanel.Visibility == Visibility.Visible)
        {
            if (_active != null)
                _active.DiffOpen = false;
            CloseDiffPanel();
            return;
        }

        // A page like Settings has no directory and no repository, so there is
        // nothing for it to show a diff of.
        if (_active?.Session == null)
            return;

        _active.DiffOpen = true;
        OpenDiffPanel();
    }

    /// <summary>
    /// Puts the panel on screen. Shared by the button and by switching to a
    /// session that already had it open, so both routes behave identically.
    /// </summary>
    private void OpenDiffPanel()
    {
        try
        {
            if (_diffView == null)
            {
                _diffView = new DiffView();
                _diffView.SetPalette(_terminalPalette);
                _diffView.SetFontFamily(_settings.FontFamily);
                _diffView.SetFileListHeight(_settings.DiffFileListHeight);
                _diffView.FileListHeightChanged += height =>
                {
                    _settings.DiffFileListHeight = height;
                    _settings.Save();
                };
                DiffPanel.Children.Add(_diffView);
                _diffView.Loaded += (_, _) => _diffView!.SetUiZoom(_settings.UiZoom);
            }

            // Math.Clamp throws when min exceeds max, and on a window narrow
            // enough that the terminal floor eats the preferred minimum, it
            // does. Take whatever room there is instead of refusing to open.
            double max = MaxDiffWidth();
            if (max < 120)
                return; // nothing worth showing
            double width = Math.Clamp(
                _settings.DiffPanelWidth * _settings.UiZoom, Math.Min(MinDiffWidth, max), max);

            DiffColumn.Width = new GridLength(width);
            DiffSplitterColumn.Width = new GridLength(SplitterGrip);
            DiffPanel.Visibility = Visibility.Visible;
            DiffResizer.Visibility = Visibility.Visible;
            DiffButton.Visibility = Visibility.Visible;
            _diffView.SetUiZoom(_settings.UiZoom);

            _ = _diffView.SetLocationAsync(LastTerminalLocation());
            DispatcherQueue.TryEnqueue(UpdateTerminalLayerLayout);
        }
        catch (Exception ex)
        {
            App.Log($"Opening changes failed: {ex}");
        }
    }

    /// <summary>
    /// Shows or hides the panel to match the session being switched to.
    ///
    /// Runs synchronously during the switch, before any git call, so the panel
    /// never flashes the previous session's state on the way in.
    /// </summary>
    private void ApplyDiffStateForActive()
    {
        bool shouldOpen = _active is { Session: not null, DiffOpen: true };

        if (!shouldOpen)
        {
            if (DiffPanel.Visibility == Visibility.Visible)
                CloseDiffPanel();
            return;
        }

        if (DiffPanel.Visibility == Visibility.Visible)
            return; // already open, nothing to do

        OpenDiffPanel();
    }

    private void CloseDiffPanel()
    {
        DiffColumn.Width = new GridLength(0);
        DiffSplitterColumn.Width = new GridLength(0);
        DiffPanel.Visibility = Visibility.Collapsed;
        DiffResizer.Visibility = Visibility.Collapsed;
        DispatcherQueue.TryEnqueue(UpdateTerminalLayerLayout);
    }

    /// <summary>
    /// Paints the working tree's totals onto the title bar button, so the
    /// state is readable without opening the panel.
    /// </summary>
    private void OnDiffTotalsChanged(int added, int removed)
    {
        _dispatcherQueueSafe(() =>
        {
            bool any = added > 0 || removed > 0;
            DiffCounts.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
            DiffPlus.Text = added > 0 ? $"+{added}" : "";
            DiffMinus.Text = removed > 0 ? (added > 0 ? $" -{removed}" : $"-{removed}") : "";

            // Same greens and reds the diff itself uses: ANSI 2 and 1 from the
            // active palette, so the title bar agrees with the panel and both
            // follow the theme.
            DiffPlus.Foreground = PaletteBrush(2);
            DiffMinus.Foreground = PaletteBrush(1);
            DiffButton.SetValue(ToolTipService.ToolTipProperty,
                any ? $"Changes  +{added} -{removed}" : "Changes");
        });
    }

    /// <summary>A brush for one ANSI slot of the active terminal palette.</summary>
    private SolidColorBrush PaletteBrush(int ansiIndex)
    {
        uint rgb = _terminalPalette.Colors[ansiIndex];
        return new SolidColorBrush(Windows.UI.Color.FromArgb(
            0xFF, (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF)));
    }

    private void _dispatcherQueueSafe(Action action)
    {
        if (DispatcherQueue.HasThreadAccess)
            action();
        else
            DispatcherQueue.TryEnqueue(() => action());
    }

    /// <summary>
    /// Keeps the diff panel inside what the window can spare. Without this a
    /// panel opened wide on a maximised window keeps its pixel width as the
    /// window narrows, and the terminal is squeezed out from the left.
    /// </summary>
    private void OnTerminalSplitSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (DiffPanel.Visibility != Visibility.Visible)
            return;
        double max = MaxDiffWidth();
        if (DiffColumn.Width.Value > max)
            DiffColumn.Width = new GridLength(max);
    }

    private const double MinDiffWidth = 320;
    private const double SplitterGrip = 6;

    /// <summary>Never let the panel squeeze the terminal below a usable width.</summary>
    private const double MinTerminalWidth = 240;

    private double MaxDiffWidth() =>
        Math.Max(0, TerminalSplit.ActualWidth - MinTerminalWidth - SplitterGrip);

    /// <summary>
    /// The active terminal's working directory, or null when the active
    /// session is a page like Settings.
    ///
    /// It deliberately does NOT fall back to some other session's directory.
    /// Doing so made the changes button appear on the Settings page, reporting
    /// a repository the visible page has nothing to do with.
    /// </summary>
    private Zharp.Core.Remote.SessionLocation? LastTerminalLocation() => _active?.Session?.Location;

    /// <summary>
    /// Shows the title bar diff button only while the active session sits
    /// inside a git repository, and keeps an open panel pointed at it.
    /// </summary>
    private async void UpdateDiffButtonAsync()
    {
        try
        {
            var cwd = LastTerminalLocation();
            if (Equals(cwd, _diffButtonCwd))
                return;
            _diffButtonCwd = cwd;

            var repo = await GitStatus.DiscoverRepoAsync(cwd);

            // The directory may have moved on while git was answering; the
            // later call owns the button.
            if (!Equals(cwd, _diffButtonCwd))
                return;

            bool onPage = _active?.Session == null;
            bool panelOpen = DiffPanel.Visibility == Visibility.Visible;

            if (onPage)
            {
                // Settings and friends have no working directory. Showing a
                // repository's button and totals over them claimed a state
                // that had nothing to do with what was on screen.
                DiffButton.Visibility = Visibility.Collapsed;
                _diffPoll.Stop();
                return;
            }

            // The button stays while the panel is open even outside a
            // repository, because it is also the way to close the panel and
            // hiding it would strand the panel with no way to dismiss it.
            DiffButton.Visibility = repo == null && !panelOpen
                ? Visibility.Collapsed
                : Visibility.Visible;

            if (repo == null)
            {
                _diffPoll.Stop();
                OnDiffTotalsChanged(0, 0);
            }
            else
            {
                // Totals as soon as the repository is known, without waiting
                // for the panel to be opened: the button is the thing most
                // often looked at, and it used to sit blank until first click.
                await RefreshTotalsAsync(repo);
                _diffPoll.Start();
            }

            // The panel is never closed from here. Whether it is open is the
            // user's decision, and switching session, or stepping into a
            // directory that is not a repository, is not them changing it.
            // The panel says "not a git repository" for itself; closing it
            // meant coming back to that session found it gone.
            if (panelOpen && _diffView != null)
                await _diffView.SetLocationAsync(cwd);
        }
        catch (Exception ex)
        {
            App.Log($"diff button: {ex.Message}");
        }
    }

    private Microsoft.UI.Dispatching.DispatcherQueueTimer _diffPoll = null!;
    private Zharp.Core.Remote.SessionLocation? _totalsRepo;

    /// <summary>
    /// Keeps the title bar totals current while a repository is open, whether
    /// or not the panel is showing. Three seconds is slow enough that git is
    /// not being run constantly and fast enough that saving a file in an editor
    /// is reflected before you look away.
    /// </summary>
    private void StartDiffPolling()
    {
        _diffPoll = DispatcherQueue.CreateTimer();
        _diffPoll.Interval = TimeSpan.FromSeconds(3);
        _diffPoll.IsRepeating = true;
        _diffPoll.Tick += async (_, _) =>
        {
            if (_totalsRepo is { } repo)
                await RefreshTotalsAsync(repo);
        };
    }

    /// <summary>
    /// Reads the whole working tree's added and removed totals.
    ///
    /// One `git diff --numstat` covers every tracked change. Untracked files
    /// are counted from their own line count, because git has nothing to
    /// compare them against and asking it per file would undo the single-call
    /// saving entirely.
    /// </summary>
    private async Task RefreshTotalsAsync(Zharp.Core.Remote.SessionLocation repo)
    {
        try
        {
            _totalsRepo = repo;

            // Same reasoning as the panel's own poll: a repository on another
            // machine costs a network round trip to ask, so it is asked less
            // often than one on this disk.
            _diffPoll.Interval = TimeSpan.FromSeconds(repo.IsRemote ? 8 : 3);

            var numstat = await GitStatus.NumstatAsync(repo);
            int added = 0, removed = 0;
            foreach (var (a, r) in numstat.Values)
            {
                added += a;
                removed += r;
            }

            foreach (var change in await GitStatus.StatusAsync(repo))
            {
                if (change.Kind == GitChangeKind.Untracked)
                    added += await GitStatus.CountUntrackedAsync(repo, change.Path);
            }

            // The directory may have moved on while git was answering.
            if (Equals(_totalsRepo, repo))
                OnDiffTotalsChanged(added, removed);
        }
        catch (Exception ex)
        {
            App.Log($"diff totals: {ex.Message}");
        }
    }

    // ------------------------------------------------- diff panel resize grip

    private bool _resizingDiff;
    private double _diffStartX;
    private double _diffStartWidth;

    private void OnDiffSplitterPressed(object sender, PointerRoutedEventArgs e)
    {
        _resizingDiff = true;
        _diffStartX = e.GetCurrentPoint(Root).Position.X;
        _diffStartWidth = DiffColumn.ActualWidth;
        ((UIElement)sender).CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void OnDiffSplitterMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizingDiff)
            return;
        double x = e.GetCurrentPoint(Root).Position.X;
        // Dragging left widens the panel: it is anchored to the right edge.
        double max = MaxDiffWidth();
        double width = Math.Clamp(
            _diffStartWidth - (x - _diffStartX), Math.Min(MinDiffWidth, max), Math.Max(max, 1));
        DiffColumn.Width = new GridLength(width);
        e.Handled = true;
    }

    private void OnDiffSplitterReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_resizingDiff)
            return;
        _resizingDiff = false;
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);
        // Stored width is zoom-independent, matching the sidebar's.
        _settings.DiffPanelWidth = DiffColumn.ActualWidth / _settings.UiZoom;
        _settings.Save();
        e.Handled = true;
    }

    private void OnDiffSplitterCaptureLost(object sender, PointerRoutedEventArgs e) => _resizingDiff = false;

    private DiffView? _diffView;
    private Zharp.Core.Remote.SessionLocation? _diffButtonCwd;

    private string? _currentBackdrop;

    /// <summary>Applies the color theme, backdrop material and background opacity.</summary>
    private void ApplyTheme()
    {
        var spec = Themes.Get(_settings.Theme);
        Themes.ApplyToResources(spec, _settings.BackgroundOpacity);
        Root.RequestedTheme = spec.IsDark ? ElementTheme.Dark : ElementTheme.Light;
        // Overlays live outside Root (above TerminalLayer) and need the same
        // theme bucket for their {ThemeResource} lookups.
        SearchOverlay.RequestedTheme = Root.RequestedTheme;
        OnboardingOverlay.RequestedTheme = Root.RequestedTheme;

        _terminalPalette = spec.CreatePalette();
        SessionItem.IsDarkTheme = spec.IsDark;
        foreach (var item in _sessions)
        {
            item.View?.SetPalette(_terminalPalette);
            item.ThemeChanged();
        }
        _diffView?.SetPalette(_terminalPalette);
        _diffView?.SetFontFamily(_settings.FontFamily);

        SetWin32BackgroundBrush(_terminalPalette.DefaultBackground);

        // Recreate on material OR theme change (the acrylic tint is themed).
        string backdropKey = $"{_settings.Backdrop}|{spec.IsDark}";
        if (_currentBackdrop != backdropKey)
        {
            _currentBackdrop = backdropKey;
            SystemBackdrop = string.Equals(_settings.Backdrop, "acrylic", StringComparison.OrdinalIgnoreCase)
                ? new AlwaysOnAcrylicBackdrop(spec.IsDark)
                : new MicaBackdrop { Kind = MicaKind.BaseAlt };
        }
    }

    // ---------------------------------------------------------------- win32 flash fix

    private IntPtr _classBackgroundBrush;

    /// <summary>Windows paints the window CLASS background brush the moment a
    /// window is shown or restored from the taskbar, BEFORE XAML presents its
    /// first frame. The default brush is white - a visible flash on dark
    /// themes. Point it at the theme background so the pre-frame paint blends.</summary>
    private void SetWin32BackgroundBrush(uint rgb)
    {
        try
        {
            IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
            uint colorref = ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
            IntPtr brush = CreateSolidBrush(colorref);
            if (brush == IntPtr.Zero)
                return;
            SetClassLongPtr(hwnd, GCLP_HBRBACKGROUND, brush);
            // The XAML island nests child windows (compositor bridge) with
            // their own class brushes - repaint those too, or a fainter flash
            // survives on restore.
            EnumChildWindows(hwnd, (child, _) =>
            {
                SetClassLongPtr(child, GCLP_HBRBACKGROUND, brush);
                return true;
            }, IntPtr.Zero);
            // The first swap replaces WinUI's default brush (not ours to free);
            // afterwards, release the brush we created previously.
            if (_classBackgroundBrush != IntPtr.Zero)
                DeleteObject(_classBackgroundBrush);
            _classBackgroundBrush = brush;
        }
        catch (Exception ex)
        {
            App.Log("Class background brush failed: " + ex.Message);
        }
    }

    private const int GCLP_HBRBACKGROUND = -10;

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetClassLongPtrW")]
    private static extern IntPtr SetClassLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern IntPtr CreateSolidBrush(uint color);

    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    private delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);

    // ---------------------------------------------------------------- caption buttons

    private void OnMinimizeClick(object sender, RoutedEventArgs e)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
            presenter.Minimize();
    }

    private void OnMaximizeClick(object sender, RoutedEventArgs e)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            if (presenter.State == OverlappedPresenterState.Maximized)
                presenter.Restore();
            else
                presenter.Maximize();
            UpdateCaptionGlyph();
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void UpdateCaptionGlyph()
    {
        bool maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        MaximizeGlyph.Glyph = maximized ? "\uE923" : "\uE922";
    }

    private void OnSettingsChanged()
    {
        // The page that raised this change is mid-interaction - re-reading its
        // values would fight the user, snapping a slider back as they drag it.
        ApplySharedSettings(refreshSettingsPage: false);
        App.BroadcastSettings(this);
    }

    /// <summary>Re-applies the shared settings to this window's chrome and
    /// terminals. Runs in every window when any of them changes a setting.</summary>
    internal void ApplySharedSettings(bool refreshSettingsPage = true)
    {
        // A Settings page in ANOTHER window was populated when it was built, so
        // it has to be told that this change happened.
        if (refreshSettingsPage)
            _settingsView?.LoadValues();
        ApplyTheme();
        RegisterAccelerators();
        // Rebinding newTab must refresh the shortcut text shown in the menus.
        NewTabButtonSidebar.Flyout = BuildNewTabMenu();
        NewTabButtonStrip.Flyout = BuildNewTabMenu();
        EmptyStateNewTab.Flyout = BuildNewTabMenu();
        ApplySidebarDisplay();
        ApplyTabLayout();
        int cursorCode = AppSettings.CursorStyleToCode(_settings.CursorStyle);
        foreach (var item in _sessions)
        {
            if (item.Session == null || item.View == null)
                continue;
            item.Session.OverrideNoColor = _settings.OverrideNoColor;
            item.View.ApplyAppearance(_settings.FontFamily, _settings.FontSize, cursorCode);
            item.View.SetInputPosition(AppSettings.InputPositionToCode(_settings.InputPosition));
        }
    }

    // ---------------------------------------------------------------- tab dragging

    private SessionItem? _dragItem;
    private ListViewBase? _dragList;
    private PointInt32 _pressScreen;
    private Windows.Foundation.Point _grabOffset;
    private Size _cardSize;
    private bool _dragging;
    private Window? _ghost;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _dragTimer;

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr window, int index);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr window, int index, int value);

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int cx, int cy, uint flags);

    /// <summary>
    /// Pins the preview above every window and drops the frame Windows insists
    /// on drawing around it. Clearing the frame styles is what actually removes
    /// the hairline - the presenter's border-less mode does not.
    /// </summary>
    private static void PinAbove(IntPtr handle)
    {
        const int GwlStyle = -16;
        const long WsCaption = 0x00C00000L;
        const long WsThickFrame = 0x00040000L;
        const long WsBorder = 0x00800000L;
        const long WsDlgFrame = 0x00400000L;
        long style = GetWindowLongPtr(handle, GwlStyle).ToInt64();
        SetWindowLongPtr(handle, GwlStyle,
            new IntPtr(style & ~(WsCaption | WsThickFrame | WsBorder | WsDlgFrame)));

        const uint SwpNoMove = 0x0002, SwpNoSize = 0x0001;
        const uint SwpNoActivate = 0x0010, SwpFrameChanged = 0x0020;
        var topMost = new IntPtr(-1); // HWND_TOPMOST
        SetWindowPos(handle, topMost, 0, 0, 0, 0,
            SwpNoMove | SwpNoSize | SwpNoActivate | SwpFrameChanged);
    }

    private const double DragThreshold = 5;

    private static readonly bool DebugTabs =
        Environment.GetEnvironmentVariable("ZHARP_DEBUG_TABS") == "1";

    private static void LogTabs(string message)
    {
        if (DebugTabs)
            App.Log("tabs: " + message);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool GetCursorPos(out System.Drawing.Point point);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ScreenToClient(IntPtr window, ref System.Drawing.Point point);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(System.Drawing.Point point);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr window, uint flags);

    /// <summary>
    /// The Zharp window actually under a screen point, or null for the desktop
    /// or another app. Asks the system rather than comparing rectangles: torn-off
    /// windows overlap their parent by design, and a rectangle test would hand a
    /// tab to whichever window happens to be listed first rather than the one
    /// the user is looking at. The preview window is click-through, so it is
    /// never the answer.
    /// </summary>
    private static MainWindow? WindowAt(PointInt32 point)
    {
        const uint GaRoot = 2;
        IntPtr hit;
        try
        {
            hit = WindowFromPoint(new System.Drawing.Point(point.X, point.Y));
            if (hit == IntPtr.Zero)
                return null;
            hit = GetAncestor(hit, GaRoot);
        }
        catch
        {
            return null;
        }

        foreach (var window in App.Windows.ToList())
        {
            try
            {
                if (WinRT.Interop.WindowNative.GetWindowHandle(window) == hit)
                    return window;
            }
            catch
            {
                // Window already destroyed.
            }
        }
        LogTabs($"no Zharp window at {point.X},{point.Y} (hit 0x{hit.ToInt64():X})");
        return null;
    }

    /// <summary>
    /// A tab press arms the drag; everything after that is driven by polling the
    /// real cursor and mouse button rather than by pointer events. The list owns
    /// the pointer and will not share it, and events stop arriving entirely once
    /// the pointer leaves the window - which is exactly where a tab gets torn
    /// off. Polling behaves the same in every one of those cases.
    /// </summary>
    private void BeginSessionPress(SessionItem item, object sender, PointerRoutedEventArgs e)
    {
        CancelDrag();
        if (item.IsSettings)
            return; // Settings is a page, not a shell: it goes nowhere
        var list = FindSessionList(sender as DependencyObject);
        if (list == null || !e.GetCurrentPoint(null).Properties.IsLeftButtonPressed)
            return;
        if (!GetCursorPos(out var cursor))
            return;

        _dragItem = item;
        _dragList = list;
        _pressScreen = new PointInt32(cursor.X, cursor.Y);
        if (sender is FrameworkElement card)
        {
            _grabOffset = e.GetCurrentPoint(card).Position;
            _cardSize = new Size(card.ActualWidth, card.ActualHeight);
        }
        StartDragTimer();
    }

    private static ListViewBase? FindSessionList(DependencyObject? node)
    {
        while (node != null)
        {
            if (node is ListViewBase list)
                return list;
            node = VisualTreeHelper.GetParent(node);
        }
        return null;
    }

    private void StartDragTimer()
    {
        if (_dragTimer == null)
        {
            _dragTimer = DispatcherQueue.CreateTimer();
            _dragTimer.Interval = TimeSpan.FromMilliseconds(16); // follow the cursor smoothly
            _dragTimer.IsRepeating = true;
            _dragTimer.Tick += (_, _) => OnDragTick();
        }
        _dragTimer.Start();
    }

    private void OnDragTick()
    {
        if (_dragItem == null)
        {
            _dragTimer?.Stop();
            return;
        }
        const int VkLeftButton = 0x01;
        bool held = (GetAsyncKeyState(VkLeftButton) & 0x8000) != 0;
        if (!GetCursorPos(out var cursor))
        {
            CancelDrag();
            return;
        }
        var screen = new PointInt32(cursor.X, cursor.Y);

        if (!_dragging)
        {
            if (!held)
            {
                CancelDrag(); // a plain click: selection is the list's business
                return;
            }
            double moved = Math.Max(Math.Abs(screen.X - _pressScreen.X),
                Math.Abs(screen.Y - _pressScreen.Y));
            if (moved < DragThreshold)
                return;
            StartDrag();
        }

        MoveGhost(screen);
        ReorderTowards(screen);
        if (!held)
            DropDrag(screen);
    }

    private void StartDrag()
    {
        _dragging = true;
        RefreshCardOpacity();
        ShowGhost(_dragItem!);
        LogTabs($"drag start '{_dragItem!.DisplayTitle}' sessions={_sessions.Count}");
    }

    /// <summary>
    /// The carried tab lives in its own tiny window rather than in a layer of
    /// this one: a tab dragged towards the desktop has to be visible OUTSIDE
    /// the window it came from, and anything drawn inside is clipped at the
    /// window edge. It never activates and never takes a click.
    /// </summary>
    private void ShowGhost(SessionItem item)
    {
        double scale = Root.XamlRoot?.RasterizationScale ?? 1.0;
        if (scale <= 0)
            scale = 1;
        double width = _cardSize.Width > 0 ? _cardSize.Width : 200;
        double height = _cardSize.Height > 0 ? _cardSize.Height : 40;

        try
        {
            _ghost = new Window { Content = BuildGhostContent(item) };
            var handle = WinRT.Interop.WindowNative.GetWindowHandle(_ghost);

            const int GwlExStyle = -20;
            const int WsExTransparent = 0x20;   // never hit-tested
            const int WsExToolWindow = 0x80;    // stays out of the task bar
            const int WsExNoActivate = 0x8000000;
            SetWindowLong(handle, GwlExStyle,
                GetWindowLong(handle, GwlExStyle) | WsExTransparent | WsExToolWindow | WsExNoActivate);

            if (_ghost.AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.SetBorderAndTitleBar(false, false);
                presenter.IsAlwaysOnTop = true;
                presenter.IsResizable = false;
            }
            _ghost.AppWindow.Resize(new SizeInt32(
                (int)Math.Round(width * scale), (int)Math.Round(height * scale)));
            _ghost.AppWindow.Show(false); // show WITHOUT stealing focus from the drag

            // After the window exists, or the presenter puts the frame back:
            // rounded corners, and no border line - the carried tab should read
            // as the card itself, not as a little window.
            PinAbove(handle);
            const int DwmWindowCornerPreference = 33;
            int round = 2; // DWMWCP_ROUND
            DwmSetWindowAttribute(handle, DwmWindowCornerPreference, ref round, sizeof(int));

            // Windows draws a hairline frame around the window whatever the
            // presenter says, and left at its default it reads as a box around
            // the carried tab. Painting it the card's own color hides it.
            const int DwmBorderColor = 34;
            int border = CardBorderColorRef();
            int hr = DwmSetWindowAttribute(handle, DwmBorderColor, ref border, sizeof(int));
            LogTabs($"ghost frame: border=0x{border:X6} hr=0x{hr:X8}");
        }
        catch (Exception ex)
        {
            App.Log("Drag preview failed: " + ex);
            // Close it before letting go: an unreferenced window would keep the
            // process alive after every real window had closed.
            try
            {
                _ghost?.Close();
            }
            catch
            {
                // Never made it far enough to have a window.
            }
            _ghost = null;
        }
    }

    /// <summary>A lightweight stand-in for the card, carried under the cursor.</summary>
    private FrameworkElement BuildGhostContent(SessionItem item)
    {
        bool agent = item.ClaudeIconVisibility == Visibility.Visible;
        var icon = new FontIcon
        {
            FontFamily = (FontFamily)Application.Current.Resources["TablerIcons"],
            Glyph = agent ? item.AgentGlyph : item.IconGlyph,
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (agent)
            icon.Foreground = item.AgentBrush;

        var title = new TextBlock
        {
            Text = item.DisplayTitle,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 12, 0),
        };
        row.Children.Add(icon);
        row.Children.Add(title);

        // Stretches to the window instead of taking a fixed size: the window is
        // sized in physical pixels and this in logical ones, and any rounding
        // gap between the two shows up as a pale outline around the card.
        //
        // Its own window also means its own resource scope, so the theme's
        // colors have to be handed over explicitly.
        return new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
            Background = ThemeBrush("FloatingPanelBrush"),
            RequestedTheme = _settings.IsDarkTheme ? ElementTheme.Dark : ElementTheme.Light,
            Children = { row },
        };
    }

    /// <summary>The preview's surface color as a Win32 COLORREF (0x00BBGGRR).</summary>
    private int CardBorderColorRef()
    {
        var color = ThemeBrush("FloatingPanelBrush") is SolidColorBrush solid
            ? solid.Color
            : Microsoft.UI.Colors.Gray;
        return color.R | (color.G << 8) | (color.B << 16);
    }

    /// <summary>Reads a chrome brush from the palette's active theme bucket.</summary>
    private Brush ThemeBrush(string key)
    {
        var dictionaries = Application.Current.Resources.ThemeDictionaries;
        if (dictionaries.TryGetValue(_settings.IsDarkTheme ? "Dark" : "Light", out object? bucket) &&
            bucket is ResourceDictionary theme && theme.TryGetValue(key, out object? brush) &&
            brush is Brush found)
        {
            return found;
        }
        return new SolidColorBrush(Microsoft.UI.Colors.Gray);
    }

    private void MoveGhost(PointInt32 screen)
    {
        if (_ghost == null)
            return;
        double scale = Root.XamlRoot?.RasterizationScale ?? 1.0;
        if (scale <= 0)
            scale = 1;
        try
        {
            // Keep the card under the pointer exactly where it was grabbed.
            _ghost.AppWindow.Move(new PointInt32(
                screen.X - (int)Math.Round(_grabOffset.X * scale),
                screen.Y - (int)Math.Round(_grabOffset.Y * scale)));
        }
        catch
        {
            // Window went away mid-drag; the next tick tidies up.
        }
    }

    /// <summary>Screen pixels to this window's coordinates, in DIPs.</summary>
    private Windows.Foundation.Point ToClient(PointInt32 screen)
    {
        var point = new System.Drawing.Point(screen.X, screen.Y);
        try
        {
            ScreenToClient(WinRT.Interop.WindowNative.GetWindowHandle(this), ref point);
        }
        catch
        {
            return new Windows.Foundation.Point(0, 0);
        }
        double scale = Root.XamlRoot?.RasterizationScale ?? 1.0;
        if (scale <= 0)
            scale = 1;
        return new Windows.Foundation.Point(point.X / scale, point.Y / scale);
    }

    /// <summary>Slides the neighbours aside as the carried tab passes them.</summary>
    private void ReorderTowards(PointInt32 screen)
    {
        if (_dragItem == null || _dragList == null)
            return;
        var point = ToClient(screen);
        int current = _sessions.IndexOf(_dragItem);
        if (current < 0)
            return;

        for (int i = 0; i < _visibleSessions.Count; i++)
        {
            if (_dragList.ContainerFromItem(_visibleSessions[i]) is not FrameworkElement container)
                continue;
            Rect bounds;
            try
            {
                bounds = container.TransformToVisual(OuterRoot)
                    .TransformBounds(new Rect(0, 0, container.ActualWidth, container.ActualHeight));
            }
            catch
            {
                continue;
            }
            // Generous across the list's minor axis: the tab still belongs to
            // the row it is level with, even when the cursor drifts sideways.
            bool hit = ReferenceEquals(_dragList, SessionStrip)
                ? point.X >= bounds.Left && point.X <= bounds.Right &&
                  point.Y >= bounds.Top - 40 && point.Y <= bounds.Bottom + 40
                : point.Y >= bounds.Top && point.Y <= bounds.Bottom &&
                  point.X >= bounds.Left - 60 && point.X <= bounds.Right + 60;
            if (!hit)
                continue;

            int target = _sessions.IndexOf(_visibleSessions[i]);
            if (target >= 0 && target != current)
            {
                _sessions.Move(current, target);
                RefreshVisibleSessions();
                RefreshCardOpacity(); // containers were reshuffled underneath us
            }
            return;
        }
    }

    /// <summary>
    /// Released outside every Zharp window: the tab becomes a window of its own.
    /// Released over another Zharp window: that window takes it.
    /// </summary>
    private void DropDrag(PointInt32 screen)
    {
        var item = _dragItem;
        // Close the preview BEFORE asking what is under the cursor. It rides
        // directly under the pointer, so leaving it up means hit-testing finds
        // the preview instead of the window being dropped on - which reads as
        // "outside" and tears every drop off into a new window.
        ClearDragState();
        var under = WindowAt(screen);
        if (item == null || !_sessions.Contains(item))
            return;

        LogTabs($"drop at {screen.X},{screen.Y} over={(under == null ? "outside" : ReferenceEquals(under, this) ? "self" : "other")} sessions={_sessions.Count}");
        if (ReferenceEquals(under, this))
            return; // stayed home: the live reorder already placed it

        var target = under;
        if (target != null)
        {
            ReleaseSession(item);
            target.AdoptSession(item);
            target.Activate();
        }
        else
        {
            // Pulling the only tab out would just close and reopen this window.
            if (_sessions.Count == 1)
                return;
            ReleaseSession(item);
            OpenWindowFor(item, screen);
        }

        if (_sessions.Count == 0)
            Close();
    }

    /// <summary>Drops the gesture without acting on it (a plain click).</summary>
    private void CancelDrag() => ClearDragState();

    private void ClearDragState()
    {
        _dragTimer?.Stop();
        if (_ghost != null)
        {
            try
            {
                _ghost.Close();
            }
            catch
            {
                // Already gone.
            }
            _ghost = null;
        }
        _dragItem = null;
        _dragList = null;
        _dragging = false;
        RefreshCardOpacity();
    }

    /// <summary>Only the tab being carried is dimmed. The value lives on the
    /// item, so it follows the tab as the list reshuffles.</summary>
    private void RefreshCardOpacity()
    {
        foreach (var session in _sessions)
            session.DragOpacity = _dragging && ReferenceEquals(session, _dragItem) ? 0.35 : 1;
    }

    /// <summary>True when a screen point falls inside this window.</summary>
    internal bool ContainsPoint(PointInt32 point)
    {
        try
        {
            if (AppWindow.IsVisible == false)
                return false;
            var pos = AppWindow.Position;
            var size = AppWindow.Size;
            return point.X >= pos.X && point.X < pos.X + size.Width &&
                   point.Y >= pos.Y && point.Y < pos.Y + size.Height;
        }
        catch
        {
            return false; // window already destroyed
        }
    }

    /// <summary>Opens a new window around a torn-off session, under the pointer.</summary>
    private void OpenWindowFor(SessionItem item, PointInt32 dropPoint)
    {
        MainWindow window;
        try
        {
            window = new MainWindow(item);
        }
        catch (Exception ex)
        {
            // The session has already left this window's list. Take it back
            // rather than orphaning a running shell with no UI attached.
            App.Log("Tearing off a tab failed: " + ex);
            AdoptSession(item);
            return;
        }

        try
        {
            var size = AppWindow.Size;
            window.AppWindow.Resize(size);
            // Drop it so the pointer sits over the title bar, like the tab the
            // user was carrying, then keep it on screen.
            var area = DisplayArea.GetFromPoint(dropPoint, DisplayAreaFallback.Nearest)?.WorkArea;
            int x = dropPoint.X - size.Width / 3;
            int y = dropPoint.Y - 16;
            if (area is { } work)
            {
                x = Math.Clamp(x, work.X, Math.Max(work.X, work.X + work.Width - size.Width));
                y = Math.Clamp(y, work.Y, Math.Max(work.Y, work.Y + work.Height - size.Height));
            }
            window.AppWindow.Move(new PointInt32(x, y));
        }
        catch (Exception ex)
        {
            App.Log("Positioning torn-off window failed: " + ex);
        }
        window.Activate();
    }


    // ---------------------------------------------------------------- list events

    private void OnSessionSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection)
            return;
        if (e.AddedItems.Count > 0 && e.AddedItems[0] is SessionItem item)
            ActivateSession(item);
    }

    private void OnCloseSessionClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SessionItem item })
            CloseTab(item);
    }

    // The rich hover card opens INSTANTLY (the built-in tooltip delay is not
    // configurable in WinUI, so it is driven manually on hover). The open tip is
    // tracked so it can be force-closed when its card disappears - the close
    // button swallows pointer events, so PointerExited never fires for it.
    private ToolTip? _openSessionTip;

    private void OnSessionCardPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        SetCardCloseVisible(sender, true);
        if (sender is not FrameworkElement element || ToolTipService.GetToolTip(element) is not ToolTip tip)
            return;
        if (_openSessionTip != null && !ReferenceEquals(_openSessionTip, tip))
            _openSessionTip.IsOpen = false;
        _openSessionTip = tip;
        tip.IsOpen = true;
    }

    private void OnSessionCardPointerExited(object sender, PointerRoutedEventArgs e)
    {
        SetCardCloseVisible(sender, false);
        if (sender is FrameworkElement element && ToolTipService.GetToolTip(element) is ToolTip tip)
        {
            tip.IsOpen = false;
            if (ReferenceEquals(_openSessionTip, tip))
                _openSessionTip = null;
        }
    }

    /// <summary>Pressing a card dismisses the hover tip but must keep the
    /// close button visible - the pointer is still over the card.</summary>
    private void OnSessionCardPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        DismissCardTip(sender);
        if (sender is FrameworkElement { DataContext: SessionItem item })
            BeginSessionPress(item, sender, e);
    }

    /// <summary>A cancelled pointer only dismisses the tip. It must NOT touch
    /// the drag: capturing the pointer cancels it on the card, and treating
    /// that as a fresh press would throw away the drag that just began.</summary>
    private void OnSessionCardPointerCanceled(object sender, PointerRoutedEventArgs e) =>
        DismissCardTip(sender);

    private void DismissCardTip(object sender)
    {
        if (sender is FrameworkElement element && ToolTipService.GetToolTip(element) is ToolTip tip)
        {
            tip.IsOpen = false;
            if (ReferenceEquals(_openSessionTip, tip))
                _openSessionTip = null;
        }
    }

    /// <summary>The card's close button shows on hover only (sidebar cards
    /// and top-strip pills alike).</summary>
    private static void SetCardCloseVisible(object sender, bool visible)
    {
        if (sender is Grid card)
        {
            foreach (var child in card.Children)
            {
                if (child is Button close)
                {
                    close.Opacity = visible ? 1 : 0;
                    break;
                }
            }
        }
    }

    private void CloseOpenSessionTip()
    {
        if (_openSessionTip != null)
        {
            _openSessionTip.IsOpen = false;
            _openSessionTip = null;
        }
    }

    private void OnTabSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
            RefreshVisibleSessions();
    }

    // ---------------------------------------------------------------- search palette

    private void OnSearchClick(object sender, RoutedEventArgs e) => ToggleSearchOverlay();

    private void ToggleSearchOverlay()
    {
        if (SearchOverlay.Visibility == Visibility.Visible)
            CloseSearchOverlay();
        else
            OpenSearchOverlay();
    }

    private void OpenSearchOverlay()
    {
        SearchOverlay.Visibility = Visibility.Visible;
        RefreshSearchResults();
        SearchBox.SelectAll(); // keep the last query, but preselect for overwrite
        SearchBox.Focus(FocusState.Programmatic);
    }

    private void CloseSearchOverlay()
    {
        // Focus-first: move focus out before collapsing the focused subtree,
        // or it bounces to the first tab stop (sidebar toggle flash).
        if (_active?.View != null)
            _active.View.FocusTerminal();
        else if (_active?.Content is SettingsView settings)
            settings.FocusFirst();
        else if (EmptyState.Visibility == Visibility.Visible)
            EmptyStateNewTab.Focus(FocusState.Programmatic);
        SearchOverlay.Visibility = Visibility.Collapsed;
    }

    private void RefreshSearchResults()
    {
        string query = SearchBox.Text.Trim();
        var matches = query.Length == 0
            ? _sessions.ToList()
            : _sessions.Where(s =>
                s.DisplayTitle.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                s.DisplaySubtitle.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                s.Title.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
        SearchResults.ItemsSource = matches;
        SearchResults.SelectedIndex = matches.Count > 0 ? 0 : -1;
    }

    private void OnSearchBoxTextChanged(object sender, TextChangedEventArgs e)
    {
        if (SearchOverlay.Visibility == Visibility.Visible)
            RefreshSearchResults();
    }

    private void OnSearchBoxKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Escape:
                CloseSearchOverlay();
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Enter:
                if (SearchResults.SelectedItem is SessionItem hit && _sessions.Contains(hit))
                {
                    ActivateSession(hit);
                    CloseSearchOverlay();
                }
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Down:
                MoveSearchSelection(+1);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Up:
                MoveSearchSelection(-1);
                e.Handled = true;
                break;
        }
    }

    private void MoveSearchSelection(int delta)
    {
        int count = SearchResults.Items.Count;
        if (count == 0)
            return;
        int index = SearchResults.SelectedIndex;
        index = index < 0 ? 0 : (index + delta + count) % count;
        SearchResults.SelectedIndex = index;
        SearchResults.ScrollIntoView(SearchResults.SelectedItem);
    }

    private void OnSearchResultClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is SessionItem item && _sessions.Contains(item))
        {
            ActivateSession(item);
            CloseSearchOverlay();
        }
    }

    private void OnSearchScrimTapped(object sender, TappedRoutedEventArgs e) => CloseSearchOverlay();

    private void OnSearchPanelTapped(object sender, TappedRoutedEventArgs e) => e.Handled = true;

    // ---------------------------------------------------------------- shortcuts

    /// <summary>
    /// Registers all rebindable shortcuts from settings as window accelerators
    /// and rebuilds the reserved-key set the terminal must not swallow.
    /// </summary>
    private void RegisterAccelerators()
    {
        OuterRoot.KeyboardAccelerators.Clear();
        _reservedKeys.Clear();
        _blockBindings.Clear();

        foreach (var action in Shortcuts.Actions)
        {
            string binding = Shortcuts.GetBinding(_settings, action.Id);
            if (!Shortcuts.TryParse(binding, out var modifiers, out int vk))
                continue;
            if (Shortcuts.IsTerminalScope(action.Id))
            {
                // Block actions run inside the focused terminal so they can
                // fall through to the shell (full-screen apps, no marks).
                InputModifiers mods = InputModifiers.None;
                if (modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control)) mods |= InputModifiers.Ctrl;
                if (modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Shift)) mods |= InputModifiers.Shift;
                if (modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Menu)) mods |= InputModifiers.Alt;
                _blockBindings[(vk, mods)] = action.Id;
                continue;
            }
            AddAccelerator(action.Id, (Windows.System.VirtualKey)vk, modifiers);
        }

        // Fixed numpad aliases for zoom.
        AddAccelerator("zoomIn", Windows.System.VirtualKey.Add, Windows.System.VirtualKeyModifiers.Control);
        AddAccelerator("zoomOut", Windows.System.VirtualKey.Subtract, Windows.System.VirtualKeyModifiers.Control);
        AddAccelerator("zoomReset", Windows.System.VirtualKey.NumberPad0, Windows.System.VirtualKeyModifiers.Control);

        void AddAccelerator(string actionId, Windows.System.VirtualKey key, Windows.System.VirtualKeyModifiers modifiers)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, args) =>
            {
                ExecuteShortcut(actionId);
                args.Handled = true;
            };
            OuterRoot.KeyboardAccelerators.Add(accelerator);

            InputModifiers mods = InputModifiers.None;
            if (modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control)) mods |= InputModifiers.Ctrl;
            if (modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Shift)) mods |= InputModifiers.Shift;
            if (modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Menu)) mods |= InputModifiers.Alt;
            _reservedKeys.Add(((int)key, mods));
        }
    }

    private void ExecuteShortcut(string actionId)
    {
        switch (actionId)
        {
            case "newTab": AddTab(); break;
            case "closeTab": if (_active != null) CloseTab(_active); break;
            case "nextTab": CycleSession(+1); break;
            case "prevTab": CycleSession(-1); break;
            case "toggleSidebar": ToggleSidebar(); break;
            case "openSettings": OpenSettings(); break;
            case "openDiff": ToggleDiff(); break;
            case "toggleSearch": ToggleSearchOverlay(); break;
            case "zoomIn": ChangeUiZoom(+1); break;
            case "zoomOut": ChangeUiZoom(-1); break;
            case "zoomReset": ChangeUiZoom(0); break;
        }
    }

    // ---------------------------------------------------------------- title bar

    private void OnTitleBarSizeChanged(object sender, SizeChangedEventArgs e) => UpdateTitleBarPassthrough();

    /// <summary>
    /// Frameless window: nothing is draggable by default, so the title bar GAPS
    /// (bar area minus interactive controls) are declared as Caption regions -
    /// drag + double-click-maximize work there, controls stay clickable.
    /// </summary>
    private void UpdateTitleBarPassthrough()
    {
        if (Content?.XamlRoot == null)
            return;

        double scale = Content.XamlRoot.RasterizationScale;
        double barWidth = TitleBarArea.ActualWidth;
        double barHeight = TitleBarArea.ActualHeight;

        // Caption (drag) regions = the bar strip minus the interactive controls.
        var blocked = new List<(double Start, double End)>();
        foreach (FrameworkElement element in new FrameworkElement[]
                 { LeftTitleButtons, RightTitleIcons, CaptionButtons })
        {
            if (element.Visibility != Visibility.Visible || element.ActualWidth <= 0)
                continue;
            Rect bounds = element.TransformToVisual(null)
                .TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            blocked.Add((bounds.X, bounds.X + bounds.Width));
        }
        blocked.Sort((a, b) => a.Start.CompareTo(b.Start));

        var gaps = new List<RectInt32>();
        double cursor = 0;
        foreach (var (start, end) in blocked)
        {
            if (start - cursor > 2)
                AddGap(cursor, start);
            cursor = Math.Max(cursor, end);
        }
        if (barWidth - cursor > 2)
            AddGap(cursor, barWidth);

        var source = InputNonClientPointerSource.GetForWindowId(AppWindow.Id);
        source.SetRegionRects(NonClientRegionKind.Passthrough, Array.Empty<RectInt32>());
        source.SetRegionRects(NonClientRegionKind.Caption, gaps.ToArray());
        UpdateCaptionGlyph();

        void AddGap(double from, double to) => gaps.Add(new RectInt32(
            (int)Math.Round(from * scale), 0,
            (int)Math.Round((to - from) * scale),
            (int)Math.Round(barHeight * scale)));
    }

    /// <summary>Sets the taskbar/Alt-Tab icon for any of the app's windows.</summary>
    public static void TrySetWindowIcon(Window window)
    {
        try
        {
            window.AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "zharp.ico"));
        }
        catch (Exception ex)
        {
            App.Log($"Setting window icon failed: {ex.Message}");
        }
    }

    // ---------------------------------------------------------------- shutdown

    /// <summary>Records the terminals open across <paramref name="windows"/> as
    /// the set to reopen next launch.</summary>
    internal static void SaveSessionSnapshot(IReadOnlyList<MainWindow> windows, SessionItem? active = null)
    {
        var terminals = windows.SelectMany(w => w._sessions).Where(s => !s.IsSettings).ToList();
        var settings = App.Settings;
        settings.SavedSessions = terminals
            .Select(s => new SavedSession
            {
                Shell = s.ShellId ?? "",
                Directory = s.Session?.WorkingDirectory ?? "",
            })
            .ToList();
        int index = active != null ? terminals.IndexOf(active) : -1;
        settings.SavedActiveIndex = Math.Clamp(Math.Max(0, index), 0, Math.Max(0, terminals.Count - 1));
        settings.Save();
    }

    private void OnWindowClosed(object sender, WindowEventArgs args)
    {
        LogTabs($"window closing, sessions={_sessions.Count}, windows={App.Windows.Count}\n{Environment.StackTrace}");
        // Vanish instantly: the session snapshot and ConPTY teardown below
        // take ~100ms, during which XAML drops the backdrop and paints the
        // default white client brush - a visible flash unless hidden first.
        try
        {
            AppWindow.Hide();
        }
        catch
        {
            // Already destroyed - nothing to hide.
        }

        App.Windows.Remove(this);
        // Anything holding "the window the user is on" must not be left pointing
        // at this one: closing it can hand focus to another app entirely, so no
        // other window's Activated fires to correct it.
        if (ReferenceEquals(App.Main, this))
            App.Main = App.Windows.FirstOrDefault();
        // A drag in flight would leave its preview window behind, and that
        // window alone would keep the process alive after the last tab window
        // closed.
        CancelDrag();
        _updateCts.Cancel(); // stop the hourly update loop
        if (_ownsUpdateWatcher)
        {
            // Hand the hourly check to a window that is staying.
            _ownsUpdateWatcher = false;
            Interlocked.Exchange(ref _updateWatcher, 0);
            App.Windows.FirstOrDefault()?.TakeOverUpdateWatch();
        }

        // "Last location" must survive quitting the app with tabs still open,
        // not just tabs closed one by one.
        var lastTerminal = (_active is { IsSettings: false } ? _active : null)
            ?? _sessions.LastOrDefault(s => !s.IsSettings);
        if (lastTerminal?.Session?.WorkingDirectory is { Length: > 0 } dir)
            _settings.LastClosedDirectory = dir;

        // Snapshot open terminals so the next launch can pick up where this one
        // left off. Always taken: flipping restore on later should still find
        // the most recent session set. While other windows are still up they own
        // the snapshot - closing one window must not wipe the tabs that are
        // still on screen elsewhere. A whole-app shutdown snapshots every window
        // up front instead, so this step stands aside for it.
        if (!App.ClosingAll)
        {
            var owners = App.Windows.Count > 0 ? App.Windows.ToList() : new List<MainWindow> { this };
            SaveSessionSnapshot(owners, _active);
        }

        foreach (var item in _sessions)
        {
            item.View?.Dispose();
            item.Session?.Dispose();
        }
        _sessions.Clear();

        // Connections Zharp opened to read git on other machines are its own
        // to close. Leaving them would strand an ssh process per host, still
        // logged in to somebody's server after the terminal has gone.
        if (App.Windows.Count == 0)
            Zharp.Core.Remote.SshGitChannels.CloseAll();
    }
}
