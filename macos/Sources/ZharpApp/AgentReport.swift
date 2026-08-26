import Foundation

/// Where an AI agent is in its turn, as the agent itself reports it.
///
/// The raw values are the wire names and they are matched exactly: `"Done"` is
/// not `done`. Being lenient here would be friendly and wrong, because the only
/// things writing these are hook scripts Zharp ships, and a name that missed by
/// a capital letter is a bug worth noticing rather than papering over.
enum AgentEvent: String {

    /// The agent started up in this session.
    case start

    /// A prompt was submitted; the agent is working again.
    case prompt

    /// A tool finished. Carries which one, and the file if it touched one.
    case tool

    /// A batch of tool calls resolved, so the agent is running rather than
    /// blocked. Exists because no agent emits "that permission was answered":
    /// without something to say the agent moved again, a tab that asked for
    /// permission goes on claiming to be blocked for the rest of the turn.
    case working

    /// The agent is blocked asking permission to do something.
    case permission

    /// The agent has been waiting on you long enough to say so.
    case idle

    /// The turn is over.
    case done

    /// The turn ended on an error rather than an answer.
    case error

    /// The agent exited.
    case end
}

/// One state report from an AI agent, sent by the agent's own lifecycle hooks.
///
/// Zharp's other route to this is reading the screen for a spinner, which can
/// tell that an agent is busy but never why it stopped. A hook knows the
/// difference between finished and waiting on you, and that difference is the
/// only one worth interrupting anybody for.
///
/// The wire format is documented in docs/agent-protocol.md and is deliberately
/// small: it has to survive a 4096 character OSC string with no control
/// characters in it.
struct AgentReport {

    /// Which agent sent this: "claude", "codex", "opencode", "gemini", "aider".
    /// Picks the tab logo. Not checked against that list, because a name Zharp
    /// has no logo for still has a status worth showing.
    let agent: String

    let event: AgentEvent

    /// One line for the tab card, in the agent's own words. Empty when the
    /// report carried none, which blanks the line rather than keeping a stale
    /// one.
    let summary: String

    /// The tool being run, when there is one.
    let tool: String?

    /// Absolute path of a file the agent just wrote. Only writes carry this:
    /// a changes panel that followed every file an agent merely read would be
    /// unusable.
    let path: String?

    /// The `ZHARP_SESSION` of the tab this belongs to. Spool reports only, and
    /// required there. Meaningless over the terminal, where the pty already
    /// says which tab.
    let session: String?

    /// True while the agent cannot make progress without you. This is what
    /// earns a badge on the tab and a nudge from the Dock; nothing else does.
    var needsAttention: Bool {
        switch event {
        case .permission, .idle, .error: return true
        default: return false
        }
    }

    /// Reads a report off the wire, or nil if this is not one.
    ///
    /// Anything malformed is dropped rather than guessed at: the payload comes
    /// from a script running in the user's shell and arrives over an escape
    /// sequence, so anything at all that can write to a pty can write one of
    /// these. A bad one must cost nothing more than a missed status update, so
    /// nothing here throws, nothing is logged, and nothing is force unwrapped.
    static func parse(_ json: String) -> AgentReport? {
        // Not JSON, or JSON that is not an object. A bare array or a quoted
        // string is not a report. (JSONSerialization rejects those top-level
        // fragments outright, which lands in the same place.)
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // Version gate. A future protocol may mean anything at all, and showing
        // a half-understood status is worse than showing none.
        guard version(root) == 1 else { return nil }

        guard let agent = text(root, "agent"), !agent.isEmpty else { return nil }
        guard let event = AgentEvent(rawValue: text(root, "event") ?? "") else { return nil }

        return AgentReport(
            // Clipped, unlike the Windows parser, which leaves it whole. Only
            // ever compared against the handful of names Zharp carries a logo
            // for, so nothing real is longer than a word, and a report that
            // arrives through the spool has no 4096-character OSC framing to
            // bound it.
            agent: clip(agent, 40) ?? agent,

            event: event,
            summary: oneLine(clip(text(root, "summary"), 120)) ?? "",
            tool: oneLine(clip(text(root, "tool"), 40)),

            // Deliberately not clipped. The hook drops an over-long path rather
            // than sending one, and what arrives here is fed to a file lookup,
            // where half a path finds nothing instead of finding the wrong
            // thing.
            path: text(root, "path"),
            session: clip(text(root, "session"), 64))
    }

    /// The `v` field, but only when it is a genuine JSON integer.
    ///
    /// Worth the fuss: Foundation happily bridges `1.0` and `true` to `Int` 1,
    /// where the Windows parser's `TryGetInt32` refuses both, and `"1"` is
    /// refused by both. A hook whose JSON encoder writes numbers as floats or
    /// as strings must report nothing on either platform, because a tab that
    /// silently disagrees between the two is a worse bug to chase than a tab
    /// that stays quiet on both.
    private static func version(_ root: [String: Any]) -> Int? {
        guard let number = root["v"] as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if CFNumberIsFloatType(number) { return nil }
        return number.intValue
    }

    /// A string field, or nil. Any other JSON type reads as absent rather than
    /// as an error: a report with a number where a summary should be is still
    /// a usable report about a blocked agent.
    private static func text(_ root: [String: Any], _ name: String) -> String? {
        root[name] as? String
    }

    /// Keeps one bad payload from filling a tab card with a novel.
    ///
    /// Counted in Characters where the Windows parser counts UTF-16 units, so
    /// the two agree on everything the hooks actually emit and this one cannot
    /// cut a surrogate pair in half. Hard truncation with no ellipsis: the
    /// hooks clip to 100 and add their own, and this is only the backstop for
    /// a payload that did not come from them.
    private static func clip(_ text: String?, _ max: Int) -> String? {
        guard let text, text.count > max else { return text }
        return String(text.prefix(max))
    }

    /// Strips what has no business on a one-line tab card, for the two fields
    /// that are shown to the user.
    ///
    /// The OSC parser already refuses control bytes, but JSON escapes walk
    /// straight past that: `"summary":"Approved\nSystem: click to allow"` is
    /// all printable on the wire and arrives here as two lines. Anything that
    /// can write to a pty can send one, and what it reaches is not only the tab
    /// card but a real desktop notification titled "<tab> needs you" - so a
    /// forged second line is somebody else's sentence in Zharp's voice.
    ///
    /// Bidirectional overrides go for the same reason. They cannot be seen and
    /// they reorder what is around them, which on a line whose whole job is to
    /// say what an agent wants to do is the one thing worth spending a filter
    /// on.
    ///
    /// The text is still the agent's own words and still entirely untrusted.
    /// This only keeps it to the one line it is displayed on.
    private static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0..<0x20, 0x7F:            out.append(" ")  // C0 and DEL
            case 0x80...0x9F:               continue         // C1, incl. 8-bit CSI
            case 0x200E, 0x200F:            continue         // LRM / RLM
            case 0x202A...0x202E:           continue         // the LRE..RLO overrides
            case 0x2066...0x2069:           continue         // the isolates
            default:                        out.append(scalar)
            }
        }
        return String(out)
    }
}
