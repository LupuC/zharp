using Microsoft.UI.Xaml;
using Microsoft.Windows.AppNotifications;

namespace Zharp.App;

public partial class App : Application
{
    private Window? _window;

    /// <summary>The window last activated, for HWND interop (file/folder
    /// pickers) and for anything that needs "the window the user is on".</summary>
    public static Window? Main { get; internal set; }

    /// <summary>Every open window, in creation order. Tearing a tab out of a
    /// window adds one; closing a window removes it.</summary>
    public static List<MainWindow> Windows { get; } = new();

    /// <summary>One settings instance for the whole process - separate copies
    /// per window would overwrite each other's saves.</summary>
    public static AppSettings Settings { get; } = AppSettings.Load();

    /// <summary>True while <see cref="CloseAllWindows"/> is tearing the app
    /// down, so individual windows leave the session snapshot alone.</summary>
    internal static bool ClosingAll { get; private set; }

    /// <summary>
    /// Closes every window. Used when the updater hands over to the installer.
    /// The snapshot of open tabs is taken HERE, across all windows, before any
    /// of them closes: a window on its way out only ever sees the windows that
    /// are left, so letting them snapshot one by one would restore just the
    /// last one's tabs after the update.
    /// </summary>
    public static void CloseAllWindows()
    {
        var open = Windows.ToList();
        MainWindow.SaveSessionSnapshot(open);
        ClosingAll = true;
        try
        {
            foreach (var window in open)
                window.Close();
        }
        finally
        {
            ClosingAll = false;
        }
    }

    /// <summary>Applies a settings change made in <paramref name="source"/> to
    /// every other window, so themes and layout stay in sync across windows.</summary>
    public static void BroadcastSettings(MainWindow source)
    {
        foreach (var window in Windows.ToList())
        {
            if (!ReferenceEquals(window, source))
                window.ApplySharedSettings();
        }
    }

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            Log($"Unhandled: {e.Exception}");
            e.Handled = true;
        };
    }

    /// <summary>Appends a line to %LOCALAPPDATA%\Zharp\error.log (best effort).</summary>
    public static void Log(string message)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zharp");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "error.log"),
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never take the app down.
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            // Toast support for the update notifier. Subscribe before Register
            // so clicks land even for toasts shown earlier this session.
            AppNotificationManager.Default.NotificationInvoked += (_, e) =>
            {
                // Zharp raises more than one kind of notification now, so the
                // click has to be routed. Untagged means the update toast,
                // which is the only one that predates the argument.
                e.Arguments.TryGetValue("action", out string? action);
                e.Arguments.TryGetValue("session", out string? session);

                (Main as MainWindow)?.DispatcherQueue.TryEnqueue(() =>
                {
                    if (action == "agent" && int.TryParse(session, out int id))
                        MainWindow.ShowAgentSession(id);
                    else
                        (Main as MainWindow)?.ShowUpdatePage();
                });
            };
            AppNotificationManager.Default.Register();
        }
        catch (Exception ex)
        {
            Log("Notification registration failed: " + ex);
        }

        // Reports from agents that cannot write to a terminal arrive here.
        // Started before any session exists, so nothing can be missed.
        AgentSpool.Start();

        // Nothing is dialled from here. This only records whether Zharp is
        // allowed to, for the first time a session goes somewhere over ssh.
        Zharp.Core.Remote.SshGitChannels.Enabled = Settings.RemoteGit;

        // Off the launch path: these read and may rewrite files on disk, and
        // nothing on screen is waiting for the answer. New sessions pick the
        // hooks up whenever it lands.
        Task.Run(() =>
        {
            ClaudeCodeIntegration.Sync(Settings.AgentIntegration);

            // Codex will not run a hook it has not been told to trust, so a
            // fresh install owes the user an explanation. Recorded rather than
            // acted on here: the place to say it is a terminal, and there is
            // not one yet.
            if (CodexIntegration.Sync(Settings.AgentIntegration))
                Settings.CodexNoticeFor = "";

            OpenCodeIntegration.Sync(Settings.AgentIntegration);
        });

        _window = new MainWindow();
        Main = _window;
        _window.Activate();
    }
}
