# AI agent CLIs: how they surface status, and how Zharp can read it

Goal: the sidebar should mirror an agent's live activity, for example Claude Code's
`✢ Perambulating… (2m 33s · ↓ 6.5k tokens)`, with the animated state, elapsed
time and token counts, for every agent we recognize (Claude Code, OpenCode,
Codex, Gemini CLI, Aider). This document maps out where that information
lives per tool and which channels Zharp can tap.

## What Zharp already has

- **Full buffer access.** The emulator owns every cell the agent draws,
  main and alternate screen alike. Anything the agent renders (spinner line,
  token counters, footers) is readable text for us. No other terminal has a
  better vantage point.
- **Title stream.** `TitleChanged` events (OSC 0/2) already drive agent
  detection (`SessionItem.KnownAgents`).
- **Redraw notifications.** `OutputArrived` fires after every pty chunk, which
  is a natural throttle point for status scraping.
- **Process ownership.** Zharp spawns the ConPTY, so the shell's child
  process tree is enumerable (Toolhelp32 snapshot): `claude` (node),
  `codex` (rust), `aider` (python)… This can detect agents that never set a
  title, and process CPU time is a crude busy signal.

## Signal channels, best to worst

| Channel | Reliability | Latency | Effort | Notes |
|---|---|---|---|---|
| Native API (OpenCode) | high | realtime | medium | documented HTTP endpoint |
| Hooks/notify (Claude, Codex) | high | on events | medium-high | requires touching user config |
| Terminal title | high | coarse | trivial | already flowing through Zharp |
| Buffer scraping | medium | realtime | low | per-tool regex, breaks on UI changes |
| OSC 9;4 progress | n/a today | realtime | low | agents largely don't emit it yet |

## Per-agent notes

### Claude Code (`claude`)

- **Renderer:** Ink (React for CLIs), repaints a live region at the bottom of
  the MAIN buffer (no alternate screen in normal chat use).
- **Spinner line:** `<glyph> <Verb>… (<elapsed> · ↓ <n> tokens)` plus an
  "esc to interrupt" hint. The glyph animates through the asterisk family
  (`·✢✳✶✻✽` etc.); verbs are whimsical gerunds ("Perambulating",
  "Cogitating", …) so match the SHAPE, not a word list:
  `^[·✢✳✶✻✽*]\s+\S+…\s*\((\d+[hms].*?)(?:·\s*[↓↑]\s*([\d.,]+k?)\s*tokens)?` on
  the last ~6 rows of the main screen.
- **Title:** since v2.1.6 Claude Code sets the terminal title itself to a
  spinner glyph + short task description while working (tracked in
  anthropics/claude-code issues #17887, #56933), so BUSY/IDLE state and a
  task summary already arrive through our existing `TitleChanged` path.
  Completion state is encoded as a title prefix; it does NOT emit OSC 9;4
  progress today (issue #2686 asks for exactly that).
- **Hooks:** user-configurable hooks (`PreToolUse`, `PostToolUse`,
  `Notification`, `Stop` in `~/.claude/settings.json`) run arbitrary
  commands. Zharp could ship an optional hook that reports state
  transitions to a named pipe. The `statusLine` setting also feeds a user
  command a JSON payload (model, cost, duration) it renders in the TUI.
- **Practical plan:** title glyph → busy/idle; buffer regex → verb, elapsed,
  token count. Hooks are a later opt-in upgrade.

### Codex CLI (`codex`, OpenAI)

- **Renderer:** Rust/ratatui, ALTERNATE screen (full TUI). Zharp still has
  the alt-buffer cells, so scraping works, just scan the alt buffer.
- **Status:** header shows `• Working (<n>s • Esc to interrupt)`;
  footer status line is configurable (`[tui] status_line = ["model",
  "token-usage", "branch"]`) and shows "% context left".
- **Title:** `[tui] terminal_title = ["spinner", "project"]` is the DEFAULT, so
  Codex broadcasts its spinner through the title, which we already receive.
- **Notify:** `notify = ["cmd"]` in `config.toml` runs a program on turn
  events; `[tui] notification_method` controls in-terminal notifications.
- **Practical plan:** title spinner → busy/idle for free; alt-buffer regex on
  `Working \((\d+)s` and `(\d+)% context left` for detail.

### OpenCode (`opencode`, sst)

- **Renderer:** client/server. The TUI is just a client of a local HTTP
  server that exposes an OpenAPI 3.1 spec, including
  `GET /session/status` for the state of every session, plus message and
  token accounting endpoints.
- **Practical plan:** the richest integration of all. Detect the opencode
  child process, find its server port, poll `/session/status`. Buffer
  scraping of the Bubble Tea alt-screen TUI is the fallback.

### Gemini CLI (`gemini`, Google)

- **Renderer:** Ink, like Claude Code. Open source (google-gemini/gemini-cli)
  so render strings are verifiable in-source.
- **Status:** spinner + "witty" loading phrases (user-customizable via
  `ui.customWittyPhrases`, so NEVER match phrase text) with elapsed seconds;
  the footer shows model and `<n>% context left`.
- **Practical plan:** regex the elapsed/`% context left` shapes; phrase text
  is decoration only.

### Aider (`aider`)

- **Renderer:** prompt_toolkit REPL on the MAIN buffer, plain streamed text.
- **Status:** a spinner animation while waiting for the LLM to start
  streaming ("Knight Rider" style bar); after each response it prints
  `Tokens: <sent> sent, <received> received. Cost: $<n>` lines.
- **Title/detection:** does not reliably set a title, so process-tree
  detection matters here.
- **Practical plan:** busy = spinner row present; token/cost regex on the
  scrollback for the stats.

## Proposed Zharp architecture (when we build it)

1. `AgentStatus` record on `SessionItem`: `Busy`, `Verb/Phase`, `Elapsed`,
   `Tokens`, `ContextLeft`, whatever a given source can fill. The sidebar
   renders what exists (animated glyph + "2m 33s · 6.5k tokens" second line).
2. A per-agent `IAgentStatusReader` with two tiers:
   - Tier 1 (all agents, day one): title-based busy state + throttled buffer
     regex (run on `OutputArrived`, at most every ~250 ms, only while an
     agent is detected, only over the last N rows of the active buffer).
   - Tier 2 (opt-in, later): OpenCode HTTP polling, Claude Code hooks,
     Codex notify.
3. Detection hardening: add process-tree matching beside title matching, so
   Aider (no title) still badges.

## Verify empirically before building

Each tool's exact strings drift between versions. Before implementing, run
each CLI inside Zharp with `ZHARP_DUMP_PTY=<file>` set and capture a session:
start a prompt, let it work, interrupt once, let one finish. That gives the
authoritative byte stream (spinner glyphs, title sequences, redraw pattern)
for the versions actually in use. Build the regexes from those dumps, not
from documentation.

## Sources

- Codex TUI/title/notify config: developers.openai.com/codex/config-reference
- OpenCode server + session status API: opencode.ai/docs/server,
  deepwiki.com/sst/opencode (Session Management, TUI)
- Claude Code title spinner + OSC 9;4 discussion: github.com/anthropics/
  claude-code issues #17887, #2686, #56933
- Gemini CLI loading phrases + footer: google-gemini/gemini-cli issues
  #7639, #9066; docs get-started/configuration
- Aider spinner + token/cost output: Aider-AI/aider issue #2538,
  aider.chat/HISTORY.html
