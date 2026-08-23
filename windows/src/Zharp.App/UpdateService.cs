using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;

namespace Zharp.App;

/// <summary>
/// Update channel: asks the website for the newest released version, downloads
/// the installer through it, and hands off to a silent Inno Setup upgrade that
/// relaunches Zharp when done.
/// </summary>
public static class UpdateService
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(15) };

    public static Version CurrentVersion { get; } = GetCurrentVersion();

    private static Version GetCurrentVersion()
    {
        // InformationalVersion carries the clean SemVer; SourceLink may append
        // "+<commit>", which Version.Parse rejects.
        string? info = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (info != null)
        {
            int metadata = info.IndexOf('+');
            if (metadata >= 0)
                info = info[..metadata];
            if (Version.TryParse(info, out var parsed))
                return Normalize(parsed);
        }
        return Assembly.GetExecutingAssembly().GetName().Version is { } asmVersion
            ? Normalize(asmVersion)
            : new Version(0, 0, 0);
    }

    /// <summary>Three-part form so 0.1.0 == 0.1.0.0 comparisons behave.</summary>
    private static Version Normalize(Version v) =>
        new(v.Major, Math.Max(v.Minor, 0), Math.Max(v.Build, 0));

    /// <summary>Latest released version per the website, or null if unreachable.</summary>
    public static async Task<Version?> GetLatestAsync(string baseUrl)
    {
        // The site serves per-platform releases now that macOS ships too.
        // Omitting the parameter still answers for Windows, but asking
        // explicitly keeps this correct if that default ever changes.
        using var response = await Http.GetAsync($"{baseUrl.TrimEnd('/')}/api/version?platform=windows");
        if (!response.IsSuccessStatusCode)
            return null;
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        if (doc.RootElement.TryGetProperty("version", out var versionElement) &&
            Version.TryParse(versionElement.GetString(), out var version))
        {
            return Normalize(version);
        }
        return null;
    }

    /// <summary>Downloads the newest installer to %TEMP% and returns its path.
    /// Progress is the 0..1 fraction, or null when the size is unknown.</summary>
    public static async Task<string> DownloadInstallerAsync(string baseUrl, IProgress<double?>? progress)
    {
        string path = Path.Combine(Path.GetTempPath(), $"ZharpSetup-update-{Guid.NewGuid():N}.exe");
        using var response = await Http.GetAsync(
            $"{baseUrl.TrimEnd('/')}/download?platform=windows", HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();

        long? total = response.Content.Headers.ContentLength;
        await using var source = await response.Content.ReadAsStreamAsync();
        await using var destination = File.Create(path);
        var buffer = new byte[1 << 16];
        long done = 0;
        int read;
        while ((read = await source.ReadAsync(buffer)) > 0)
        {
            await destination.WriteAsync(buffer.AsMemory(0, read));
            done += read;
            progress?.Report(total > 0 ? (double)done / total.Value : null);
        }
        return path;
    }

    /// <summary>Starts the silent upgrade; the caller must close the app right
    /// after so the installer can replace its files. /RELAUNCH=1 makes the
    /// installer start Zharp again when it finishes.</summary>
    public static void RunInstaller(string installerPath)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = installerPath,
            // /CURRENTUSER keeps the upgrade per-user even if Zharp happens to
            // run elevated - otherwise the installer would fork a second copy
            // into Program Files.
            Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /RELAUNCH=1",
            UseShellExecute = true,
        });
    }
}
