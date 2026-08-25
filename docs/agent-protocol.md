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

## The wire format

The agent's hook writes one OSC 777 notification per event:

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

Events:

| Event | Fires when | Zharp shows |
|---|---|---|
| `start` | the agent starts in this session | the agent's logo on the tab |
| `prompt` | a prompt is submitted | working |
| `tool` | a tool that writes a file finished | the file it wrote, and the changes panel follows it |
| `permission` | the agent is blocked asking permission | **needs you** |
| `idle` | the agent has been waiting long enough to say so | **needs you** |
| `done` | the turn ended | done, in green |
| `error` | the turn ended on an error | **needs you** |
| `end` | the agent exited | nothing; the tab goes back to being a shell |

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

**Hooks cost real time.** Each hook invocation spawns a process, which on
Windows is around 260ms for a PowerShell host. That is why the write-file hook
is filtered to the tools that actually write, rather than firing after every
tool call: a busy turn makes dozens of tool calls and would pay the cost for
every one of them.

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

Implemented. The hook script ships with Zharp at
`Integrations/ClaudeCode/zharp-agent.ps1` and is installed from
**Settings → AI agents**, which adds hook entries to `~/.claude/settings.json`
and takes them back out again on disconnect.

| Zharp event | Claude Code hook | Matcher |
|---|---|---|
| `start` | `SessionStart` | `startup\|resume\|clear` |
| `prompt` | `UserPromptSubmit` | |
| `tool` | `PostToolUse` | `Edit\|Write\|NotebookEdit` |
| `permission` | `PermissionRequest` | |
| `idle` | `Notification` | `idle_prompt` |
| `done` | `Stop` | |
| `error` | `StopFailure` | |
| `end` | `SessionEnd` | |

### Codex

Not yet. Codex uses the same event names behind a `features.hooks` flag, and
has a `commandWindows` key for a Windows specific command, so the mapping
should be close to identical.

### Gemini CLI

Not yet. Gemini CLI has had hooks since v0.26.0, including `Notification` and
`Stop`, configured in `~/.gemini/settings.json`.

### OpenCode, Aider

Not yet. Both are recognized on the tab card by name, with status read from the
screen.
