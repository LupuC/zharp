using System.Text.Json;

namespace Zharp.App;

/// <summary>Where an AI agent is in its turn, as the agent itself reports it.</summary>
public enum AgentEvent
{
    /// <summary>The agent started up in this session.</summary>
    Start,

    /// <summary>A prompt was submitted; the agent is working again.</summary>
    Prompt,

    /// <summary>A tool finished. Carries which one, and the file if it touched one.</summary>
    Tool,

    /// <summary>
    /// A batch of tool calls resolved, so the agent is running rather than
    /// blocked. Exists because no agent emits "that permission was answered":
    /// without something to say the agent moved again, a tab that asked for
    /// permission goes on claiming to be blocked for the rest of the turn.
    /// </summary>
    Working,

    /// <summary>The agent is blocked asking permission to do something.</summary>
    Permission,

    /// <summary>The agent has been waiting on you long enough to say so.</summary>
    Idle,

    /// <summary>The turn is over.</summary>
    Done,

    /// <summary>The turn ended on an error rather than an answer.</summary>
    Error,

    /// <summary>The agent exited.</summary>
    End,
}

/// <summary>
/// One state report from an AI agent, sent by the agent's own lifecycle hooks.
///
/// Zharp's other route to this is reading the screen for a spinner, which can
/// tell that an agent is busy but never why it stopped. A hook knows the
/// difference between finished and waiting on you, and that difference is the
/// only one worth interrupting anybody for.
///
/// The wire format is documented in docs/agent-protocol.md and is deliberately
/// small: it has to survive a 4096-byte OSC string with no control characters.
/// </summary>
public sealed record AgentReport(
    string Agent,
    AgentEvent Event,
    string Summary,
    string? Tool,
    string? Path,
    string? Session)
{
    /// <summary>
    /// True while the agent cannot make progress without you. This is what
    /// earns a badge on the tab and a nudge from the taskbar; nothing else does.
    /// </summary>
    public bool NeedsAttention => Event is AgentEvent.Permission or AgentEvent.Idle or AgentEvent.Error;

    /// <summary>
    /// Reads a report off the wire, or null if this is not one.
    ///
    /// Anything malformed is dropped rather than guessed at: the payload comes
    /// from a script running in the user's shell, so it is untrusted input that
    /// happens to arrive over a terminal escape sequence. A bad one must cost
    /// nothing more than a missed status update.
    /// </summary>
    public static AgentReport? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return null;

            // Version gate. A future protocol may mean anything at all, and
            // showing a half-understood status is worse than showing none.
            if (!root.TryGetProperty("v", out var version)
                || !version.TryGetInt32(out int v) || v != 1)
                return null;

            string? agent = Text(root, "agent");
            if (string.IsNullOrEmpty(agent))
                return null;

            if (ParseEvent(Text(root, "event")) is not { } ev)
                return null;

            return new AgentReport(
                agent,
                ev,
                Clip(Text(root, "summary"), 120) ?? "",
                Clip(Text(root, "tool"), 40),
                Text(root, "path"),

                // Only the spool needs this: a report that arrives down a pty
                // is already addressed by having come out of that pty.
                Clip(Text(root, "session"), 64));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    /// <summary>Keeps one bad payload from filling a tab card with a novel.</summary>
    private static string? Clip(string? text, int max) =>
        text is { Length: > 0 } && text.Length > max ? text[..max] : text;

    private static AgentEvent? ParseEvent(string? name) => name switch
    {
        "start" => AgentEvent.Start,
        "prompt" => AgentEvent.Prompt,
        "tool" => AgentEvent.Tool,
        "working" => AgentEvent.Working,
        "permission" => AgentEvent.Permission,
        "idle" => AgentEvent.Idle,
        "done" => AgentEvent.Done,
        "error" => AgentEvent.Error,
        "end" => AgentEvent.End,
        _ => null,
    };
}
