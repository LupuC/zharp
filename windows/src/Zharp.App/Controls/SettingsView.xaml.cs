using System.Diagnostics;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Zharp.App.Controls;

/// <summary>
/// The settings page, hosted as a tab in the main window:
/// a navigation rail of pages on the left, setting cards on the right.
/// Changes are saved immediately and broadcast via <see cref="Changed"/>.
/// </summary>
public sealed partial class SettingsView : UserControl
{
    private readonly AppSettings _settings;
    private bool _ready;
    private readonly FrameworkElement[] _pages;

    /// <summary>Raised after any setting has been modified and saved.</summary>
    public event Action? Changed;

    public SettingsView(AppSettings settings)
    {
        _settings = settings;
        InitializeComponent();

        // About stays last: ShowAbout() selects by the end of this list.
        _pages = [AppearancePage, TerminalPage, ShellPage, AgentsPage, ShortcutsPage, AboutPage];
        LoadValues();
        NavRail.SelectedIndex = 0;
    }

    /// <summary>
    /// Reads the current settings into the controls. Also used to re-sync when
    /// another window changes something: this page is cached, so without it a
    /// second Settings tab keeps showing - and acting on - stale values.
    /// </summary>
    public void LoadValues()
    {
        _ready = false; // populating must not look like the user editing

        ThemeGrid.ItemsSource = ThemeCard.All;
        ThemeGrid.SelectedIndex = Math.Max(0, Array.FindIndex(Themes.All,
            t => string.Equals(t.Id, _settings.Theme, StringComparison.OrdinalIgnoreCase)));
        BackdropCombo.SelectedIndex =
            string.Equals(_settings.Backdrop, "acrylic", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
        OpacitySlider.Value = Math.Clamp(_settings.BackgroundOpacity * 100, 50, 100);
        LayoutCombo.SelectedIndex = _settings.UseSidebar ? 0 : 1;
        DensityCombo.SelectedIndex = _settings.SidebarCompact ? 1 : 0;
        TitleModeCombo.SelectedIndex = _settings.SidebarTitleIsCwd ? 1 : 0;
        ShowPathToggle.IsOn = _settings.SidebarShowPath;
        ShowSearchToggle.IsOn = _settings.SidebarShowSearch;
        BuildShortcutRows();
        RefreshClaudeRow();

        var familyNames = CanvasTextFormat.GetSystemFontFamilies()
            .OrderBy(f => f, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (!familyNames.Contains(_settings.FontFamily, StringComparer.OrdinalIgnoreCase))
            familyNames.Insert(0, _settings.FontFamily);
        // Each entry renders in its own face (preview-in-list).
        var fontOptions = familyNames
            .Select(name => new FontOption(name, new Microsoft.UI.Xaml.Media.FontFamily(name)))
            .ToList();
        FontFamilyCombo.ItemsSource = fontOptions;
        FontFamilyCombo.SelectedItem = fontOptions.First(f =>
            string.Equals(f.Name, _settings.FontFamily, StringComparison.OrdinalIgnoreCase));

        FontSizeBox.Value = _settings.FontSize;
        CursorStyleCombo.SelectedIndex = _settings.CursorStyle.ToLowerInvariant() switch
        {
            "underline" => 1,
            "bar" => 2,
            _ => 0,
        };
        ScrollbackBox.Value = _settings.ScrollbackLines;
        InputPositionGrid.SelectedIndex = AppSettings.InputPositionToCode(_settings.InputPosition);
        ShellCombo.SelectedIndex = _settings.Shell.ToLowerInvariant() switch
        {
            "pwsh" => 1,
            "powershell" => 2,
            "cmd" => 3,
            _ => 0,
        };
        PwshItem.IsEnabled = ShellDiscovery.IsPwshAvailable;
        NoColorToggle.IsOn = _settings.OverrideNoColor;
        RestoreSessionsToggle.IsOn = _settings.RestoreSessions;
        DefaultDirBox.Text = _settings.DefaultDirectory;
        AboutVersion.Text = $"Version {UpdateService.CurrentVersion}";
        if (_availableUpdate == null)
            UpdateStatus.Text = $"Zharp {UpdateService.CurrentVersion}";

        _ready = true;
    }

    /// <summary>Zoom-dependent layout metrics (fonts are handled by ChromeZoom).</summary>
    public void SetZoom(double zoom)
    {
        NavColumn.Width = new Microsoft.UI.Xaml.GridLength(180 * zoom);
    }

    /// <summary>Moves keyboard focus into the page (used when this tab activates).</summary>
    public void FocusFirst() => NavRail.Focus(FocusState.Programmatic);

    /// <summary>Jumps to the About page (update toast click target).</summary>
    public void ShowAbout() => NavRail.SelectedIndex = _pages.Length - 1;

    /// <summary>Scrolls the current page to the bottom (used by tests).</summary>
    public void ScrollToEnd() => PageScroller.ChangeView(null, PageScroller.ScrollableHeight, null, true);

    private bool _updateBusy;
    private Version? _availableUpdate;

    /// <summary>Arms the update button directly ("Update now"), used when the
    /// title-bar badge or the toast already knows a newer version exists.</summary>
    public void PrepareUpdate(Version latest)
    {
        if (_updateBusy || latest <= UpdateService.CurrentVersion)
            return;
        _availableUpdate = latest;
        UpdateStatus.Text = $"Zharp {latest} is available (you have {UpdateService.CurrentVersion}).";
        UpdateButton.Content = "Update now";
    }

    private async void OnCheckUpdates(object sender, RoutedEventArgs e)
    {
        if (_updateBusy)
            return;
        _updateBusy = true;
        var button = (Button)sender;
        try
        {
            if (_availableUpdate == null)
            {
                UpdateStatus.Text = "Checking…";
                var latest = await UpdateService.GetLatestAsync(_settings.UpdateBaseUrl);
                if (latest == null)
                {
                    UpdateStatus.Text =
                        $"Zharp {UpdateService.CurrentVersion} - could not reach the update server.";
                }
                else if (latest > UpdateService.CurrentVersion)
                {
                    _availableUpdate = latest;
                    UpdateStatus.Text =
                        $"Zharp {latest} is available (you have {UpdateService.CurrentVersion}).";
                    button.Content = "Update now";
                }
                else
                {
                    UpdateStatus.Text = $"You're up to date - Zharp {UpdateService.CurrentVersion}.";
                }
            }
            else
            {
                button.IsEnabled = false;
                var progress = new Progress<double?>(fraction =>
                    UpdateStatus.Text = fraction is { } f
                        ? $"Downloading update… {f:P0}"
                        : "Downloading update…");
                string installer =
                    await UpdateService.DownloadInstallerAsync(_settings.UpdateBaseUrl, progress);
                UpdateStatus.Text = "Installing… Zharp will restart.";
                UpdateService.RunInstaller(installer);
                App.CloseAllWindows(); // records state, then the installer takes over
            }
        }
        catch (Exception ex)
        {
            App.Log("Update failed: " + ex);
            UpdateStatus.Text = "Update failed - see error.log.";
            button.IsEnabled = true;
        }
        finally
        {
            _updateBusy = false;
        }
    }

    private void Commit()
    {
        if (!_ready)
            return;
        _settings.Save();
        Changed?.Invoke();
    }

    // ---------------------------------------------------------------- navigation

    private void OnNavChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_pages == null)
            return;
        int index = NavRail.SelectedIndex;
        for (int i = 0; i < _pages.Length; i++)
            _pages[i].Visibility = i == index ? Visibility.Visible : Visibility.Collapsed;

        // Claude Code's settings file is edited by hand and by Claude Code
        // itself. Re-reading it on the way in beats showing what was true when
        // this page was last built.
        if (ReferenceEquals(_pages[index], AgentsPage))
            RefreshClaudeRow();
    }

    // ---------------------------------------------------------------- AI agents

    private void RefreshClaudeRow()
    {
        if (!ClaudeCodeIntegration.IsClaudeCodePresent)
        {
            ClaudeStatusText.Text = "Not installed on this machine.";
            ClaudeConnectButton.Content = "Connect";
            ClaudeConnectButton.IsEnabled = false;
            ClaudeHint.Text = "";
            return;
        }

        bool connected = ClaudeCodeIntegration.IsConnected();
        ClaudeConnectButton.IsEnabled = true;
        ClaudeConnectButton.Content = connected ? "Disconnect" : "Connect";
        ClaudeStatusText.Text = connected
            ? "Reporting its own status to Zharp."
            : "Status is being read off the screen.";

        // Say plainly which file gets written. It is the user's config, they
        // did not ask for it to be a surprise, and knowing where it is is how
        // they undo this without us.
        ClaudeHint.Text = connected
            ? $"Hooks live in {ClaudeCodeIntegration.SettingsPath}. Disconnecting removes them and leaves the rest of the file alone."
            : $"Adds lifecycle hooks to {ClaudeCodeIntegration.SettingsPath}, pointing at a script that ships with Zharp. Nothing else in that file is changed, and the hooks do nothing in other terminals.";
    }

    private void OnClaudeConnectClick(object sender, RoutedEventArgs e)
    {
        try
        {
            if (ClaudeCodeIntegration.IsConnected())
                ClaudeCodeIntegration.Disconnect();
            else
                ClaudeCodeIntegration.Connect();

            RefreshClaudeRow();

            // Hooks are read when a session starts, so nothing already running
            // changes. Better to say so than to let them wonder why.
            ClaudeHint.Text += " Open a new Claude Code session for this to take effect.";
        }
        catch (Exception ex)
        {
            App.Log($"claude code: {ex.Message}");
            ClaudeStatusText.Text = "Could not update the Claude Code settings.";
            ClaudeHint.Text = ex.Message;
        }
    }

    // ---------------------------------------------------------------- handlers

    private void OnDensityChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.SidebarDensity = DensityCombo.SelectedIndex == 1 ? "compact" : "comfortable";
        Commit();
    }

    private void OnTitleModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.SidebarTitleMode = TitleModeCombo.SelectedIndex == 1 ? "cwd" : "shell";
        Commit();
    }

    private void OnShowPathToggled(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _settings.SidebarShowPath = ShowPathToggle.IsOn;
        Commit();
    }

    private void OnShowSearchToggled(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _settings.SidebarShowSearch = ShowSearchToggle.IsOn;
        Commit();
    }

    private void OnThemeSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        if (ThemeGrid.SelectedItem is ThemeCard card)
        {
            _settings.Theme = card.Id;
            Commit();
        }
    }

    private void OnBackdropChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.Backdrop = BackdropCombo.SelectedIndex == 1 ? "acrylic" : "mica";
        Commit();
    }

    private void OnOpacityChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.BackgroundOpacity = Math.Clamp(e.NewValue / 100.0, 0.5, 1.0);
        Commit();
    }

    private void OnLayoutChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.TabLayout = LayoutCombo.SelectedIndex == 1 ? "top" : "sidebar";
        _settings.SidebarVisible = true;
        Commit();
    }

    /// <summary>One font-picker entry: the name plus its renderable face.</summary>
    public sealed record FontOption(string Name, Microsoft.UI.Xaml.Media.FontFamily Family);

    private void OnFontFamilyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        if (FontFamilyCombo.SelectedItem is FontOption option && option.Name.Length > 0)
        {
            _settings.FontFamily = option.Name;
            Commit();
        }
    }

    private void OnFontSizeChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_ready || double.IsNaN(args.NewValue)) return;
        _settings.FontSize = Math.Clamp(args.NewValue, 7, 36);
        Commit();
    }

    private void OnCursorStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.CursorStyle = CursorStyleCombo.SelectedIndex switch
        {
            1 => "underline",
            2 => "bar",
            _ => "block",
        };
        Commit();
    }

    private void OnInputPositionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.InputPosition = InputPositionGrid.SelectedIndex switch
        {
            1 => "bottom",
            2 => "pinTop",
            _ => "top",
        };
        Commit();
    }

    private void OnScrollbackChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_ready || double.IsNaN(args.NewValue)) return;
        _settings.ScrollbackLines = (int)Math.Clamp(args.NewValue, 100, 200000);
        Commit();
    }

    private void OnShellChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.Shell = ShellCombo.SelectedIndex switch
        {
            1 => "pwsh",
            2 => "powershell",
            3 => "cmd",
            _ => "auto",
        };
        Commit();
    }

    private void OnNoColorToggled(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _settings.OverrideNoColor = NoColorToggle.IsOn;
        Commit();
    }

    private void OnRestoreSessionsToggled(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        _settings.RestoreSessions = RestoreSessionsToggle.IsOn;
        // Save without the Changed broadcast: only the next launch reads this.
        _settings.Save();
    }

    private void OnDefaultDirChanged(object sender, TextChangedEventArgs e)
    {
        if (!_ready) return;
        _settings.DefaultDirectory = DefaultDirBox.Text.Trim();
        // Save without the Changed broadcast: nothing live depends on this,
        // and it fires per keystroke while the user types a path.
        _settings.Save();
    }

    private async void OnBrowseDefaultDir(object sender, RoutedEventArgs e)
    {
        if (App.Main is not Window window)
            return;
        try
        {
            // The WinAppSDK picker; the Windows.Storage one throws 0x80004005
            // in unpackaged apps (no package identity).
            var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(window.AppWindow.Id);
            var result = await picker.PickSingleFolderAsync();
            if (result != null)
                DefaultDirBox.Text = result.Path; // TextChanged persists it
        }
        catch (Exception ex)
        {
            App.Log("Folder picker failed: " + ex);
        }
    }

    // ---------------------------------------------------------------- shortcuts

    private ShortcutAction? _capturingAction;
    private Button? _captureButton;

    private void BuildShortcutRows()
    {
        foreach (var action in Shortcuts.Actions)
        {
            var row = new Grid { ColumnSpacing = 16, Padding = new Thickness(0, 6, 0, 6) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var label = new TextBlock
            {
                Text = action.DisplayName,
                FontSize = 13,
                VerticalAlignment = VerticalAlignment.Center,
            };
            row.Children.Add(label);

            var button = new Button
            {
                Content = Shortcuts.GetBinding(_settings, action.Id),
                MinWidth = 150,
                FontSize = 12,
                HorizontalAlignment = HorizontalAlignment.Right,
                Tag = action,
            };
            button.Click += OnShortcutButtonClick;
            button.PreviewKeyDown += OnShortcutCaptureKeyDown;
            button.LostFocus += (_, _) => { if (_captureButton == button) CancelCapture(); };
            Grid.SetColumn(button, 1);
            row.Children.Add(button);

            ShortcutsPanel.Children.Add(row);
        }
    }

    private void OnShortcutButtonClick(object sender, RoutedEventArgs e)
    {
        CancelCapture();
        _captureButton = (Button)sender;
        _capturingAction = (ShortcutAction)_captureButton.Tag;
        _captureButton.Content = "Press shortcut…";
        ShortcutHint.Text = "";
    }

    private void OnShortcutCaptureKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (_capturingAction == null || !ReferenceEquals(sender, _captureButton))
            return;
        e.Handled = true;

        var key = e.Key;
        if (key is Windows.System.VirtualKey.Escape)
        {
            CancelCapture();
            return;
        }
        if (key is Windows.System.VirtualKey.Control or Windows.System.VirtualKey.Shift
            or Windows.System.VirtualKey.Menu or Windows.System.VirtualKey.LeftWindows
            or Windows.System.VirtualKey.RightWindows or Windows.System.VirtualKey.LeftControl
            or Windows.System.VirtualKey.RightControl or Windows.System.VirtualKey.LeftShift
            or Windows.System.VirtualKey.RightShift or Windows.System.VirtualKey.LeftMenu
            or Windows.System.VirtualKey.RightMenu)
        {
            return; // wait for the actual key
        }

        var modifiers = Windows.System.VirtualKeyModifiers.None;
        if (IsDown(Windows.System.VirtualKey.Control)) modifiers |= Windows.System.VirtualKeyModifiers.Control;
        if (IsDown(Windows.System.VirtualKey.Shift)) modifiers |= Windows.System.VirtualKeyModifiers.Shift;
        if (IsDown(Windows.System.VirtualKey.Menu)) modifiers |= Windows.System.VirtualKeyModifiers.Menu;

        if (!modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control) &&
            !modifiers.HasFlag(Windows.System.VirtualKeyModifiers.Menu))
        {
            ShortcutHint.Text = "Shortcuts must include Ctrl or Alt.";
            return;
        }

        string? binding = Shortcuts.Format(modifiers, (int)key);
        if (binding == null)
        {
            ShortcutHint.Text = "That key isn't supported for shortcuts.";
            return;
        }

        foreach (var other in Shortcuts.Actions)
        {
            if (other.Id != _capturingAction.Id &&
                string.Equals(Shortcuts.GetBinding(_settings, other.Id), binding, StringComparison.OrdinalIgnoreCase))
            {
                ShortcutHint.Text = $"Already used by \"{other.DisplayName}\".";
                return;
            }
        }

        _settings.Keybindings[_capturingAction.Id] = binding;
        _captureButton.Content = binding;
        _capturingAction = null;
        _captureButton = null;
        ShortcutHint.Text = "";
        Commit();

        static bool IsDown(Windows.System.VirtualKey key) =>
            Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    }

    private void CancelCapture()
    {
        if (_captureButton != null && _capturingAction != null)
            _captureButton.Content = Shortcuts.GetBinding(_settings, _capturingAction.Id);
        _capturingAction = null;
        _captureButton = null;
    }

    private void OnOpenSettingsFolder(object sender, RoutedEventArgs e)
    {
        try
        {
            _settings.Save(); // make sure the file exists
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{AppSettings.SettingsPath}\"")
            {
                UseShellExecute = true,
            });
        }
        catch
        {
            // Explorer launch failures are non-fatal.
        }
    }
}
