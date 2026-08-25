# Agent status protocol

How an AI coding agent tells Zharp what it is doing.

## Why there is a protocol at all

Zharp can already tell that an agent is running: it watches the commands you
type and the titles the program sets, and it reads the visible screen looking
for a spinner. That is enough to show a logo on the tab and a line of live
status, and for a long time it was all there was.

It cannot answer the question that actually matters when you have six tabs
open, which is **which one is waiting for me**. A spinner that has stopped
might mean the agent finished, or it might mean the agent is sitting on a
permission prompt you have not seen. From the outside those look identical.

Every modern agent CLI can answer that question directly, because they all
expose lifecycle hooks. This protocol is the shape of that answer.

## Two ways in

The payload below is the same whichever way it travels. Only the transport
differs, and which one an agent uses is decided by the agent, not by us.

**Through the terminal.** The hook returns an escape sequence, the agent writes
it to the pty, and Zharp reads it back out. Nothing is written to disk and
nothing needs routing: whatever comes out of a pty belongs to that pty's tab.
This is the better transport and it is used wherever it is available, which
today means Claude Code.

**Through a spool directory.** The hook writes its report into
`%LOCALAPPDATA%\Zharp\agents` and Zharp picks it up. This is for agents with no
way to return a terminal sequence, which is most of them: a hook process has no
controlling terminal of its own, and on Windows there is not even a `/dev/tty`
to borrow. Codex and OpenCode work this way.

The spool has to answer a question the pty answers for free: which tab. It is
not guessed from the working directory, which cannot separate two agents in one
repository. Zharp puts a unique `ZHARP_SESSION` in the environment of every
shell it starts, the hook inherits it, and the report carries it back.

Each report is a separate file, written under a name the watcher ignores and
then renamed into place. A rename within one directory is atomic, so a reader
can never see half a report and there is no read offset to keep in step with a
writer. Reports are deleted as they are read; anything found at startup is
delivered rather than discarded, because it is a report that arrived while
Zharp was not running.

## The wire format

Over the terminal, the agent's hook writes one OSC 777 notification per event:

```
ESC ] 777 ; notify ; zharp://agent ; <json> BEL
```

OSC 777 with a `notify` verb is the rxvt-unicode desktop notification
convention, and it is what the agent CLIs and the terminals integrating with
them have converged on. The title field is the namespace: Zharp reads
`zharp://agent` and ignores everything else, so another terminal's
notifications passing through are not mistaken for ours.

The JSON body:

| Field | Required | Meaning |
|---|---|---|
| `v` | yes | Protocol version. Currently `1`. A body with any other version is dropped rather than half read. |
| `agent` | yes | Which agent: `claude`, `codex`, `gemini`, `opencode`, `aider`. Picks the logo. |
| `event` | yes | One of the events below. |
| `summary` | no | One line for the tab card, in the agent's own words. Clipped to 100 characters. |
| `tool` | no | The tool being run, when there is one. |
| `path` | no | Absolute path of a file the agent just **wrote**. |
| `session` | spool only | The `ZHARP_SESSION` of the tab this belongs to. Meaningless over the terminal, where the pty already says. |

Events:

| Event | Fires when | Zharp shows |
|---|---|---|
| `start` | the agent starts in this session | the agent's logo on the tab |
| `prompt` | a prompt is submitted | working, with the turn clock running |
| `tool` | a tool that writes a file finished | the file it wrote, and the changes panel follows it |
| `working` | a batch of tool calls resolved | nothing new, unless it clears a stale "needs you" |
| `permission` | the agent is blocked asking permission | **needs you**, and how long it has been waiting |
| `idle` | the agent has been waiting long enough to say so | **needs you**, and how long it has been waiting |
| `done` | the turn ended | done, in green, with how long the turn took |
| `error` | the turn ended on an error | **needs you** |
| `end` | the agent exited | nothing; the tab goes back to being a shell |

Every state carries an elapsed time, but not the same one, because the useful
number is different in each. While the agent works it counts from the prompt,
so moving between tools does not reset it. While it is blocked it counts from
the moment it blocked, because "waiting 4m" is the number that makes you go
look. When the turn ends it freezes at the total.

"Needs you" is the only state that badges the tab, flashes the taskbar and
raises a notification, and it is the reason the protocol exists. Everything
else is there so that the status line says something true.

## Constraints worth knowing

**The body has to survive an OSC string.** Zharp's parser accepts 4096 bytes
and drops anything below 0x20, so the JSON must be escaped with no raw control
characters. Every JSON encoder does this already; the thing to watch is total
length, which is why `summary` is clipped and `path` is dropped rather than
allowed to overflow.

**Only writes carry a `path`.** Agents read far more files than they write, and
a changes panel that jumped to every file the agent merely looked at would be
unusable. Reads, searches and shell commands report a `summary` and no path.

**What a hook costs decides what to subscribe to, and it is not the same for
each agent.** This is the thing to check before designing anything else.

| | how a hook runs | cost of one |
|---|---|---|
| Claude Code | an argument list, no shell | one process |
| Codex | a command line, so `cmd.exe` on Windows | two processes |
| OpenCode | a function call, in process | nothing |

Measured: a PowerShell host starts in ~139ms, node in ~48ms. Zharp subscribed
Codex to `PostToolUse` before checking, which is two processes for every tool
call an agent makes; you could watch them appear and the terminal was slower
for it. Codex now gets one hook, for the one thing that cannot be worked out
any other way. OpenCode, where a hook is free, gets everything useful.

**The hook must be silent outside Zharp.** Zharp sets `ZHARP_AGENT_PROTOCOL` in
the environment of every shell it starts. A hook that does not find it exits
without printing anything, so the same hook can live in a config file shared
with every other terminal on the machine and cost nothing there.

## Delivering the sequence

A hook process has no controlling terminal of its own, and on Windows there is
no `/dev/tty` to borrow even if it did. Agents solve this by letting the hook
return the escape sequence and writing it to the pty themselves. In Claude Code
that is the `terminalSequence` field:

```json
{ "terminalSequence": "]777;notify;zharp://agent;{\"v\":1,...}" }
```

## Per-agent notes

### Claude Code

Implemented, and on by default. The hook script ships with Zharp at
`Integrations/ClaudeCode/zharp-agent.ps1`, and Zharp installs the hooks into
`~/.claude/settings.json` at startup without being asked.

That is a deliberate choice and worth defending, because writing to somebody
else's config file usually is not one. An integration you have to go and find
is one almost nobody switches on, and the entire value here is that Zharp knows
what your agent is doing without you having set anything up. What makes it
acceptable is that it is narrow and reversible:

- only hook entries are added; every other key in the file is left exactly as
  it was, including hooks the user wrote themselves on the same events
- a copy of the original is kept beside it the first time Zharp touches it
- the write is a move over the top, so a crash halfway cannot truncate it
- the hooks do nothing in any other terminal, because the script exits
  immediately when `ZHARP_AGENT_PROTOCOL` is absent
- nothing is written at all if Claude Code is not installed
- `"agentIntegration": false` in Zharp's own settings stops it and takes the
  hooks back out

That last one has no switch in the Settings UI, deliberately. Agent support is
part of the terminal rather than a feature to go and find, and a tab that
cannot say its agent is blocked is the whole thing this exists to fix. The key
is there for somebody deploying Zharp where touching an agent's config is not
allowed, not as a preference to weigh up.

What *is* in Settings is whether being interrupted is welcome: **Terminal →
Notifications** controls the desktop notification and taskbar flash raised when
an agent needs you and Zharp is not the window in front. The tab badge is not
part of that and always shows.

Startup also repairs the hooks rather than only adding them. An update moves
the executable, which leaves hooks pointing at a script path that no longer
exists; those look installed but are dead, so Zharp checks that each hook names
the current script and rewrites the set when any of them does not.

| Zharp event | Claude Code hook | Matcher |
|---|---|---|
| `start` | `SessionStart` | `startup\|resume\|clear` |
| `prompt` | `UserPromptSubmit` | |
| `tool` | `PostToolUse` | `Edit\|Write\|NotebookEdit` |
| `working` | `PostToolBatch` | |
| `permission` | `PermissionRequest` | |
| `idle` | `Notification` | `idle_prompt` |
| `done` | `Stop` | |
| `error` | `StopFailure` | |
| `end` | `SessionEnd` | |

### Codex

Implemented, through the spool. Verified against codex-cli 0.145.0.

The events line up almost exactly with Claude Code's, but the transport does
not exist: there is no `terminalSequence` field, and the documentation is
explicit that a hook's stdout is JSON or model context and never reaches the
terminal. Checking the shipped binary agrees, and it is also missing
`PostToolBatch`. So Codex reports through the spool, and `PostToolUse` is
unfiltered rather than limited to writes, because it is then the only thing
that can say the agent is running again after a permission prompt was
answered.

That is affordable here because the hook is node rather than PowerShell.
Codex ships as an npm package, so node is always present where Codex is, and
it starts in roughly a third of the time: ~48ms against ~139ms measured.

| Zharp event | Codex hook | Matcher |
|---|---|---|
| `start` | `SessionStart` | |
| `prompt` | `UserPromptSubmit` | |
| `tool` | `PostToolUse` | |
| `permission` | `PermissionRequest` | |
| `done` | `Stop` | |
| `end` | `SessionEnd` | |

Codex has no equivalent of Claude's `idle_prompt` notification or of
`StopFailure`, so there is no `idle` or `error` report from it.

Three things are specific to Codex and worth knowing.

**Hooks must be trusted before they run.** Codex asks on next start ("N hooks
need review before they can run"), and until that is answered a Codex tab
reports nothing. Zharp does not try to route around this, which would be
defeating a safety feature that exists for precisely the case of a program
writing hooks into your agent. Instead the first session after the hooks are
installed opens with a line saying the prompt is coming, so a quiet tab is not
mistaken for a broken one.

**`notify` is not usable.** It holds a single program and OpenAI's own tooling
already claims it on many machines, so taking it would break whatever was
there. Hooks are the only way in.

**Config goes to `~/.codex/hooks.json`, not `config.toml`.** Both are read and
the JSON one takes precedence. `config.toml` is full of the user's own project
trust settings, and rewriting TOML round trips badly; the JSON file is usually
ours alone.

Editing is done through `apply_patch`, whose input is a patch rather than a
filename, so the file the changes panel follows is read out of the
`*** Update File:` line in the patch body and resolved against the session's
working directory.

### Gemini CLI

Not yet. Gemini CLI has had hooks since v0.26.0, including `Notification` and
`Stop`, configured in `~/.gemini/settings.json`.

### OpenCode

Implemented, through the spool, and the cheapest of the three. Verified against
opencode 1.15.6.

OpenCode loads plugins into its own process, so a hook is a function call:
there is no shell, no process to spawn, and nothing to pay per tool call. That
is why this subscribes to what it needs rather than to the least it can get
away with, which is the shape Codex forced.

| Zharp event | OpenCode hook or event |
|---|---|
| `prompt` | `chat.message` |
| `permission` | `permission.ask` |
| `working` | `permission.replied` |
| `tool` | `file.edited` |
| `done` | `session.idle` |

It is the only one of the three that reports a permission having been
**answered**, so nothing is inferred there. `file.edited` hands over the path
directly, so the changes panel follows along without a patch to parse, and
`Permission.title` is already the sentence OpenCode's own dialog shows, so
there is no per-tool wording to invent.

The plugin is copied into OpenCode's config directory and registered in
`opencode.json` by a path relative to it. An absolute Windows path in that list
would be ambiguous with an npm package name, and a relative one is what
OpenCode's own plugins use. Plugins load when a session starts rather than at
startup, so a newly installed one takes effect on the next session.

### Aider

Not yet. Recognized on the tab card by name, with status read from the screen.
