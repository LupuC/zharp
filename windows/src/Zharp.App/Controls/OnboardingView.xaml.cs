using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Zharp.App.Controls;

/// <summary>
/// First-run onboarding steps: welcome, theme pick, shortcuts, done.
/// Shown once (settings "onboarded"); Skip and Finish both mark it done.
/// </summary>
public sealed partial class OnboardingView : UserControl
{
    /// <summary>One row on the shortcuts step.</summary>
    public sealed record ShortcutRow(string Name, string Keys);

    private readonly AppSettings _settings;
    private readonly FrameworkElement[] _steps;
    private readonly bool _ready;
    private int _step;

    /// <summary>Raised when a setting changed (theme pick) and needs applying.</summary>
    public event Action? Changed;

    /// <summary>Raised when onboarding is finished or skipped.</summary>
    public event Action? Finished;

    public OnboardingView(AppSettings settings)
    {
        _settings = settings;
        InitializeComponent();

        _steps = [Step0, Step1, Step2, Step3];

        ThemeGrid.ItemsSource = ThemeCard.All;
        ThemeGrid.SelectedIndex = Math.Max(0, Array.FindIndex(Themes.All,
            t => string.Equals(t.Id, _settings.Theme, StringComparison.OrdinalIgnoreCase)));

        ShortcutList.ItemsSource = new[]
        {
            new ShortcutRow("New terminal", Shortcuts.GetBinding(_settings, "newTab")),
            new ShortcutRow("Search sessions", Shortcuts.GetBinding(_settings, "toggleSearch")),
            new ShortcutRow("Cycle sessions", Shortcuts.GetBinding(_settings, "nextTab")),
            new ShortcutRow("Toggle the tab panel", Shortcuts.GetBinding(_settings, "toggleSidebar")),
            new ShortcutRow("Zoom the whole UI", "Ctrl + = / -"),
            new ShortcutRow("Open settings", Shortcuts.GetBinding(_settings, "openSettings")),
        };

        BuildDots();
        SetStep(0);
        _ready = true;

        Loaded += (_, _) => NextButton.Focus(FocusState.Programmatic);
    }

    private void BuildDots()
    {
        for (int i = 0; i < _steps.Length; i++)
        {
            Dots.Children.Add(new TextBlock
            {
                Text = "●",
                FontSize = 8,
                Opacity = 0.25,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
    }

    private void SetStep(int step)
    {
        _step = Math.Clamp(step, 0, _steps.Length - 1);
        for (int i = 0; i < _steps.Length; i++)
        {
            _steps[i].Visibility = i == _step ? Visibility.Visible : Visibility.Collapsed;
            ((TextBlock)Dots.Children[i]).Opacity = i == _step ? 0.9 : 0.25;
        }
        BackButton.Visibility = _step > 0 ? Visibility.Visible : Visibility.Collapsed;
        SkipButton.Visibility = _step < _steps.Length - 1 ? Visibility.Visible : Visibility.Collapsed;
        NextButton.Content = _step switch
        {
            0 => "Get started",
            var s when s == _steps.Length - 1 => "Finish",
            _ => "Next",
        };
        NextButton.Focus(FocusState.Programmatic);
    }

    private void OnNext(object sender, RoutedEventArgs e)
    {
        if (_step < _steps.Length - 1)
            SetStep(_step + 1);
        else
            Complete();
    }

    private void OnBack(object sender, RoutedEventArgs e) => SetStep(_step - 1);

    private void OnSkip(object sender, RoutedEventArgs e) => Complete();

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
        {
            Complete();
            e.Handled = true;
        }
    }

    private void Complete()
    {
        _settings.Onboarded = true;
        _settings.Save();
        Finished?.Invoke();
    }

    private void OnThemeSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready)
            return;
        if (ThemeGrid.SelectedItem is ThemeCard card)
        {
            _settings.Theme = card.Id;
            _settings.Save();
            Changed?.Invoke();
        }
    }
}
