using System.Text.Json;
using System.Text.Json.Nodes;

namespace Zharp.App;

/// <summary>
/// Connects OpenCode to Zharp.
///
/// The cheapest of the three by a distance. OpenCode loads plugins into its own
/// process, so a hook is a function call: no shell, no process, nothing to pay
/// per tool call. That is why this subscribes to what it needs rather than to
/// the least it can get away with, which is the shape the Codex integration was
/// forced into.
///
/// It is also the only one of the three that says when a permission has been
/// answered, so nothing has to be inferred.
///
/// The plugin is copied into OpenCode's own config directory and referenced
/// from there. An absolute Windows path in the plugin list would be ambiguous
/// with an npm package name, and a path relative to the config directory is
/// what OpenCode's own plugins use.
/// </summary>
public static class OpenCodeIntegration
{
    private const string PluginFileName = "zharp-agent.js";

    /// <summary>Where OpenCode expects the entry, relative to its config.</summary>
    private const string PluginEntry = "./plugin/" + PluginFileName;

    /// <summary>The copy that ships with Zharp.</summary>
    public static string SourcePath { get; } = Path.Combine(
        AppContext.BaseDirectory, "Integrations", "OpenCode", PluginFileName);

    /// <summary>OpenCode's config directory.</summary>
    public static string ConfigDirectory { get; } =
        Environment.GetEnvironmentVariable("ZHARP_OPENCODE_CONFIG") is { Length: > 0 } custom
            ? custom
            : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config", "opencode");

    public static string ConfigPath => Path.Combine(ConfigDirectory, "opencode.json");

    /// <summary>Where the plugin is installed to.</summary>
    public static string InstalledPluginPath =>
        Path.Combine(ConfigDirectory, "plugin", PluginFileName);

    public static bool IsOpenCodePresent =>
        Directory.Exists(ConfigDirectory)
        || ShellDiscovery.FindOnPath("opencode.cmd") != null
        || ShellDiscovery.FindOnPath("opencode.exe") != null;

    /// <summary>Registered in the config right now.</summary>
    public static bool IsConnected()
    {
        try
        {
            return Read()?["plugin"] is JsonArray list && list.Any(IsOurs);
        }
        catch (Exception ex)
        {
            App.Log($"opencode: could not read config: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Registered, and running the plugin this build ships. The file is copied
    /// rather than referenced, so an update has to refresh the copy: comparing
    /// the contents is what notices that.
    /// </summary>
    public static bool IsCurrent()
    {
        try
        {
            if (!IsConnected())
                return false;
            if (!File.Exists(InstalledPluginPath) || !File.Exists(SourcePath))
                return false;
            return File.ReadAllText(InstalledPluginPath) == File.ReadAllText(SourcePath);
        }
        catch (Exception ex)
        {
            App.Log($"opencode: could not compare the plugin: {ex.Message}");
            return false;
        }
    }

    /// <summary>Installs or refreshes the plugin, or removes it when off.</summary>
    public static void Sync(bool enabled)
    {
        try
        {
            if (!IsOpenCodePresent)
                return;

            if (!enabled)
            {
                if (!IsConnected())
                    return;
                Disconnect();
                App.Log($"opencode: plugin removed from {ConfigPath}");
                return;
            }

            if (IsCurrent())
                return;

            Connect();
            App.Log($"opencode: plugin installed at {InstalledPluginPath}");
        }
        catch (Exception ex)
        {
            App.Log($"opencode: could not install the plugin: {ex.Message}");
        }
    }

    public static void Connect()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(InstalledPluginPath)!);
        File.Copy(SourcePath, InstalledPluginPath, overwrite: true);

        var root = Read() ?? new JsonObject();

        // OpenCode's own config carries this, and a file without it is one we
        // are creating from nothing.
        root["$schema"] ??= "https://opencode.ai/config.json";

        if (root["plugin"] is not JsonArray list)
        {
            list = new JsonArray();
            root["plugin"] = list;
        }

        DropOurs(list);
        list.Add(PluginEntry);

        Write(root);
    }

    public static void Disconnect()
    {
        try { File.Delete(InstalledPluginPath); } catch { }

        if (Read() is not { } root)
            return;

        if (root["plugin"] is JsonArray list)
        {
            DropOurs(list);
            if (list.Count == 0)
                root.Remove("plugin");
        }

        // A config that now says nothing but its schema is one we created.
        if (root.Count == 0 || (root.Count == 1 && root["$schema"] != null))
        {
            try { File.Delete(ConfigPath); } catch { }
            return;
        }

        Write(root);
    }

    /// <summary>Matched on the file name, so a differently rooted entry from an
    /// older install is still recognized and replaced.</summary>
    private static bool IsOurs(JsonNode? entry) =>
        entry?.GetValue<string>() is { Length: > 0 } text
        && text.Contains(PluginFileName, StringComparison.OrdinalIgnoreCase);

    private static void DropOurs(JsonArray list)
    {
        for (int i = list.Count - 1; i >= 0; i--)
        {
            if (IsOurs(list[i]))
                list.RemoveAt(i);
        }
    }

    private static JsonObject? Read()
    {
        if (!File.Exists(ConfigPath))
            return null;
        string text = File.ReadAllText(ConfigPath);
        if (string.IsNullOrWhiteSpace(text))
            return null;
        return JsonNode.Parse(text, documentOptions: new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        }) as JsonObject;
    }

    private static void Write(JsonObject root)
    {
        Directory.CreateDirectory(ConfigDirectory);

        string backup = ConfigPath + ".zharp-backup";
        if (File.Exists(ConfigPath) && !File.Exists(backup))
            File.Copy(ConfigPath, backup);

        string json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        string temp = ConfigPath + ".zharp-tmp";
        File.WriteAllText(temp, json);
        File.Move(temp, ConfigPath, overwrite: true);
    }
}
