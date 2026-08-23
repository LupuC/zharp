using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zharp.App;

/// <summary>One executed command, with where and when it ran.</summary>
public sealed class HistoryEntry
{
    [JsonPropertyName("cmd")]
    public string Command { get; set; } = "";

    [JsonPropertyName("dir")]
    public string? Directory { get; set; }

    [JsonPropertyName("shell")]
    public string Shell { get; set; } = "";

    [JsonPropertyName("when")]
    public DateTimeOffset When { get; set; }
}

/// <summary>
/// Cross-shell, cross-session command history, fed by the terminal's
/// command-capture pipeline (Enter capture + prompt-mark confirmation) and
/// persisted to %LOCALAPPDATA%\Zharp\history.json. Thread-safe: commands
/// arrive from pty reader threads and the UI thread alike.
/// </summary>
public sealed class HistoryStore
{
    private const int Cap = 5000;

    private static readonly Lazy<HistoryStore> Lazy = new(() => new HistoryStore());
    public static HistoryStore Instance => Lazy.Value;

    private readonly object _lock = new();
    private readonly List<HistoryEntry> _entries = new(); // oldest first
    private int _saveScheduled;

    public static string HistoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Zharp", "history.json");

    private HistoryStore()
    {
        try
        {
            if (File.Exists(HistoryPath))
            {
                var loaded = JsonSerializer.Deserialize<List<HistoryEntry>>(File.ReadAllText(HistoryPath));
                if (loaded != null)
                    _entries.AddRange(loaded.Where(e => !string.IsNullOrWhiteSpace(e.Command)));
            }
        }
        catch
        {
            // Corrupt history starts fresh - never block the terminal on it.
        }
    }

    public void Add(string command, string? directory, string shell)
    {
        command = command.Trim();
        if (command.Length == 0 || command.Length > 500)
            return;

        lock (_lock)
        {
            // One entry per command: reusing a command moves it to the front
            // (with the fresh directory and timestamp) instead of stacking.
            // This also absorbs the double-report per command (Enter capture
            // + the next prompt's confirmation).
            _entries.RemoveAll(e => string.Equals(e.Command, command, StringComparison.Ordinal));
            _entries.Add(new HistoryEntry
            {
                Command = command,
                Directory = directory,
                Shell = shell,
                When = DateTimeOffset.Now,
            });
            if (_entries.Count > Cap)
                _entries.RemoveRange(0, _entries.Count - Cap);
        }
        ScheduleSave();
    }

    /// <summary>Newest-first snapshot, deduplicated by command text (the most
    /// recent occurrence wins), optionally scoped to one directory.</summary>
    public List<HistoryEntry> Query(string? filter = null, string? directory = null, int limit = 100)
    {
        lock (_lock)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var result = new List<HistoryEntry>(Math.Min(limit, _entries.Count));
            for (int i = _entries.Count - 1; i >= 0 && result.Count < limit; i--)
            {
                var entry = _entries[i];
                if (directory != null &&
                    !string.Equals(entry.Directory, directory, StringComparison.OrdinalIgnoreCase))
                    continue;
                if (!string.IsNullOrEmpty(filter) &&
                    !entry.Command.Contains(filter, StringComparison.OrdinalIgnoreCase))
                    continue;
                if (seen.Add(entry.Command))
                    result.Add(entry);
            }
            return result;
        }
    }

    public bool IsEmpty
    {
        get
        {
            lock (_lock)
                return _entries.Count == 0;
        }
    }

    private void ScheduleSave()
    {
        // Coalesce bursts: one write at most ~2s after the last add.
        if (Interlocked.Exchange(ref _saveScheduled, 1) == 1)
            return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(2));
            Interlocked.Exchange(ref _saveScheduled, 0);
            try
            {
                string json;
                lock (_lock)
                    json = JsonSerializer.Serialize(_entries);
                Directory.CreateDirectory(Path.GetDirectoryName(HistoryPath)!);
                File.WriteAllText(HistoryPath, json);
            }
            catch
            {
                // Non-fatal: history just won't persist this round.
            }
        });
    }
}
