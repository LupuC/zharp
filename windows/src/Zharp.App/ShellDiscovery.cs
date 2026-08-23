namespace Zharp.App;

/// <summary>Everything needed to launch one shell flavor.</summary>
public sealed record ShellSpec(
    string CommandLine,
    string DisplayName,
    IReadOnlyDictionary<string, string?>? ExtraEnvironment);

/// <summary>Finds installed shells and builds their launch command lines.</summary>
public static class ShellDiscovery
{
    /// <summary>
    /// Prompt hook that reports the current directory to the terminal via
    /// OSC 9;9 (the ConEmu/Windows Terminal convention). Wraps whatever prompt
    /// the user's profile installed. [char]27 keeps it PowerShell 5.1 compatible,
    /// and the snippet contains no double quotes so it embeds safely in the
    /// -Command argument.
    /// </summary>
    private const string PowerShellIntegration =
        "$global:__zharpPrompt = $function:prompt; " +
        "function global:prompt { [Console]::Write(([char]27)+']133;A'+([char]7)+([char]27)+']9;9;'+$PWD.Path+([char]7)); " +
        "(( & $global:__zharpPrompt ) -join '') + ([char]27)+']133;B'+([char]7) }";

    /// <summary>cmd.exe PROMPT with OSC 133;A/B (prompt start/end) + OSC 9;9 (cwd).</summary>
    private const string CmdPrompt = "$e]133;A$e\\$e]9;9;$P$e\\$P$G$e]133;B$e\\";

    /// <summary>Resolves a shell id ("auto"/"pwsh"/"powershell"/"cmd"/"gitbash"/"wsl").</summary>
    public static ShellSpec GetShell(string? preference)
    {
        switch (preference?.ToLowerInvariant())
        {
            case "powershell":
                return WindowsPowerShell();
            case "cmd":
                return Cmd();
            case "gitbash":
                return GitBash() ?? (Pwsh() ?? WindowsPowerShell());
            case "wsl":
                return new ShellSpec("wsl.exe", "WSL", null);
            case "pwsh":
            default:
                return Pwsh() ?? WindowsPowerShell();
        }
    }

    /// <summary>Shells actually present on this machine, for the new-tab menu.</summary>
    public static IReadOnlyList<(string Id, string Name)> GetAvailableShells()
    {
        var shells = new List<(string, string)>();
        if (IsPwshAvailable)
            shells.Add(("pwsh", "PowerShell 7"));
        shells.Add(("powershell", "Windows PowerShell"));
        shells.Add(("cmd", "Command Prompt"));
        if (GitBashPath() != null)
            shells.Add(("gitbash", "Git Bash"));
        if (FindOnPath("wsl.exe") != null)
            shells.Add(("wsl", "WSL"));
        return shells;
    }

    private static ShellSpec? GitBash()
    {
        string? path = GitBashPath();
        if (path == null)
            return null;
        // CHERE_INVOKING keeps Git Bash in the requested directory instead of $HOME.
        return new ShellSpec($"\"{path}\" --login -i", "Git Bash",
            new Dictionary<string, string?> { ["CHERE_INVOKING"] = "1" });
    }

    private static string? GitBashPath()
    {
        foreach (string? root in new[]
                 {
                     Environment.GetEnvironmentVariable("ProgramFiles"),
                     Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
                 })
        {
            if (root != null)
            {
                string candidate = Path.Combine(root, "Git", "bin", "bash.exe");
                if (File.Exists(candidate))
                    return candidate;
            }
        }
        return FindOnPath("bash.exe");
    }

    private static ShellSpec? Pwsh()
    {
        string? path = FindOnPath("pwsh.exe");
        if (path == null)
            return null;
        return new ShellSpec(
            $"\"{path}\" -NoLogo -NoExit -Command \"{PowerShellIntegration}\"",
            "PowerShell", null);
    }

    private static ShellSpec WindowsPowerShell() => new(
        $"powershell.exe -NoLogo -NoExit -Command \"{PowerShellIntegration}\"",
        "Windows PowerShell", null);

    private static ShellSpec Cmd() => new(
        "cmd.exe", "Command Prompt",
        new Dictionary<string, string?> { ["PROMPT"] = CmdPrompt });

    public static bool IsPwshAvailable => FindOnPath("pwsh.exe") != null;

    public static string? FindOnPath(string fileName)
    {
        string? pathVar = Environment.GetEnvironmentVariable("PATH");
        if (pathVar == null)
            return null;
        foreach (string dir in pathVar.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string candidate = Path.Combine(dir.Trim(), fileName);
                if (File.Exists(candidate))
                    return candidate;
            }
            catch
            {
                // Malformed PATH entry; skip.
            }
        }
        return null;
    }
}
