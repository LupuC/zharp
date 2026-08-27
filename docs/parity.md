# Feature parity

This page is the honest answer to "does my platform have feature X". The README
describes Zharp as one product, which is the goal, but the Windows and macOS
apps are separate native codebases and they do not land every feature at the
same time. When they differ, this table says so plainly rather than hiding it
behind a shared feature list.

Keeping it accurate is part of shipping a feature: **any pull request that adds,
removes or changes a user facing feature updates the relevant row here in the
same PR.** A row that is wrong is treated as a bug.

Current as of 0.19 on Windows and macOS. Linux has no code yet, so its column
is "Not yet" everywhere; it is here so the size of the port is visible.

Legend: **Yes** means shipped and usable. **Partial** means it exists but is
narrower than on the other platform, and the Notes column says how. **Not yet**
means it is not implemented.

> Every row below was checked against the source on 24 August 2026, because the
> previous version of this file was badly wrong: it listed nineteen features as
> macOS only that Windows has had all along, including command blocks, the
> history panel, tab tear-out and the AI agent status. Do not trust a row here
> without a commit that changed the code behind it.

## Terminal engine

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Native pty hosting for any installed shell | Yes | Yes | Not yet | ConPTY on Windows, `openpty` plus `posix_spawn` on macOS |
| Job control (`Ctrl+C`, `Ctrl+Z`, `fg`, `bg`) | Yes | Yes | Not yet | |
| CSI / ESC / OSC parser (VT500 style) | Yes | Yes | Not yet | |
| 16 / 256 / 24-bit truecolor, bold, italic, underline, strikethrough, inverse | Yes | Yes | Not yet | |
| Alternate screen buffer, scroll regions, origin mode | Yes | Yes | Not yet | vim, less, htop, tmux |
| DEC line drawing charset, wide CJK characters, deferred wrap | Yes | Yes | Not yet | |
| Bracketed paste, application cursor keys, focus events, device status reports | Yes | Yes | Not yet | |
| 10,000 lines of scrollback per tab | Yes | Yes | Not yet | Configurable with `scrollbackLines` |
| Correct UTF-8 across read boundaries | Yes | Yes | Not yet | |
| Text reflow on resize | Not yet | Not yet | Not yet | Both match classic conhost and do not reflow |
| Search in scrollback | Not yet | Not yet | Not yet | Searching inside one block exists on both, see below |
| Mouse reporting to applications (SGR 1006) | Not yet | Not yet | Not yet | The sequence is accepted and ignored on both |
| OSC 8 hyperlinks, OSC 52 clipboard | Not yet | Not yet | Not yet | Roadmap on both |
| Sixel and iTerm image protocols | Not yet | Not yet | Not yet | Roadmap on both |

## Rendering

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| GPU composited text rendering | Yes | Yes | Not yet | Win2D and DirectWrite on Windows, Core Text on layer-backed views on macOS |
| Crisp at any DPI or scale factor | Yes | Yes | Not yet | |
| Geometric box drawing and block elements | Not yet | Yes | Not yet | macOS draws U+2500–U+259F itself so TUI borders join seamlessly in any font. Windows renders them as font glyphs |
| Ligatures and font fallback tuning | Not yet | Not yet | Not yet | Roadmap on both |

## Command blocks and history

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Command and output grouped into addressable blocks | Yes | Yes | Not yet | |
| Jump to previous / next block | Yes | Yes | Not yet | `blockPrev` and `blockNext`, `Ctrl+Up` and `Ctrl+Down` by default |
| Collapse a block to one line | Yes | Yes | Not yet | |
| Copy command, output, whole block, or Markdown fenced block | Yes | Yes | Not yet | |
| Search within a single block, match case and regex | Yes | Yes | Not yet | `findInBlock` |
| Command history panel on Arrow Up | Yes | Yes | Not yet | Cross shell and cross session, with folder and age per entry |
| Highlighted history entry typed at the prompt live | Yes | Yes | Not yet | Enter runs what is already typed rather than sending the text again |

## Tabs and windows

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Sessions in a sidebar or a compact top strip | Yes | Yes | Not yet | `tabLayout` |
| Live working directory on the tab card | Yes | Yes | Not yet | |
| Last command run shown on the tab card | Yes | Yes | Not yet | |
| AI agent logo and live status on the tab card | Yes | Yes | Not yet | Detects Claude Code, Codex, Gemini CLI, OpenCode, Aider |
| Agents report their own status instead of it being read off the screen | Partial | Partial | Not yet | Claude Code, Codex and OpenCode on both. See [docs/agent-protocol.md](agent-protocol.md) |
| Badge, a nudge from the taskbar or Dock, and a notification when an agent is waiting for you | Yes | Yes | Not yet | Badge always; the interruptions are `Terminal > Notifications`. Windows flashes the taskbar, macOS bounces the Dock and then badges it with how many sessions are waiting |
| Changes panel follows the file an agent is editing | Yes | Yes | Not yet | Claude Code and OpenCode; Codex hooks cost too much per tool call |
| Drag a tab to reorder it | Yes | Yes | Not yet | |
| Drag a tab onto another window to hand it over, shell still running | Yes | Yes | Not yet | |
| Tear a tab out into a window of its own | Yes | Yes | Not yet | |
| Multiple windows | Yes | Yes | Not yet | |
| Reopen the tabs from the last run | Yes | Yes | Not yet | `restoreSessions` |
| New tab menu with detected shells | Yes | Yes | Not yet | PowerShell 7, Windows PowerShell, cmd, Git Bash, WSL on Windows; zsh, bash, fish, pwsh, sh on macOS |
| New tab at the last closed tab's directory | Yes | Yes | Not yet | |
| Floating session search palette | Yes | Yes | Not yet | |
| Changes panel: git diff beside the terminal | Yes | Yes | Not yet | Read-only. Changed files, per-file diff with line numbers, totals on the title bar |
| Changes panel over ssh | Yes | Yes | Not yet | Reads git on the machine the session is actually on, over a second read-only connection that never prompts and never writes. Can be turned off in Settings, where off means the panel names the machine and stops |
| Panes and splits | Not yet | Not yet | Not yet | Roadmap on both |

A session that has been sent to another machine with `ssh` is standing
somewhere the local `git` knows nothing about. Both platforms track that now:
the panel either shows the remote repository or says which machine it cannot
read and why, and the sidebar card names the host. It has a row of its own
rather than a footnote on the row above because the failure it replaced was the
one wrong answer that looks like a right one, a panel confidently describing a
repository on a computer you are no longer using.

## Shell integration

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Working directory reporting (OSC 7) | Yes | Yes | Not yet | Windows also parses OSC 9;9, the ConEmu convention |
| Knowing which machine a session is on | Yes | Yes | Not yet | Keeps the host from OSC 7, reads the `ssh` command at the prompt, and falls back to the remote shell's window title. Only a host reached by a command Zharp watched you type is one it will connect to on its own |
| Auto-injected prompt hook, no rc file editing | Yes | Yes | Not yet | Each platform hooks the shells it actually ships with: PowerShell, pwsh, cmd and bash on Windows; zsh, bash, fish and pwsh on macOS |
| Prompt and command marks (OSC 133) | Yes | Yes | Not yet | Both emit and consume `133;A` and `133;B`, which is what blocks are built on. `133;C` and `133;D` are roadmap on both |
| Strip `NO_COLOR` from spawned shells | Yes | Yes | Not yet | `overrideNoColor` |

## Selection, clipboard and scrolling

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Drag to select, trailing whitespace trimmed | Yes | Yes | Not yet | |
| Soft wrapped lines join without a break when copied | Yes | Yes | Not yet | |
| Right click copies the selection, or pastes when there is none | Yes | Yes | Not yet | |
| Scrollback pinning while output streams | Yes | Yes | Not yet | |
| Wheel scrolling, wheel to arrow keys in full screen apps | Yes | Yes | Not yet | |
| Double click word selection | Not yet | Not yet | Not yet | Roadmap on both |

## Appearance

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Slim custom title bar with sidebar, settings and search buttons | Yes | Yes | Not yet | Caption buttons on the right on Windows, beside the traffic lights on macOS |
| Themes applied live to chrome and terminal | Yes | Yes | Not yet | Both ship all nine: cream, paper, rose, dark, navy, tokyo, dracula, catppuccin, gruvbox |
| Background blur or backdrop material | Partial | Yes | Not yet | Windows uses a Mica backdrop; macOS has off, light, medium and strong, and falls back to an opaque theme colour when Reduce transparency is on |
| Background opacity setting | Yes | Yes | Not yet | `backgroundOpacity` |
| Whole UI zoom (chrome and terminal together) | Yes | Yes | Not yet | `uiZoom` |
| Per session font zoom with the wheel | Yes | Yes | Not yet | |
| Font family and size, applied live | Yes | Yes | Not yet | |
| Cursor style: block, underline, bar | Yes | Yes | Not yet | |
| Input position: classic, bottom, pinned top | Yes | Yes | Not yet | `inputPosition` |
| Draggable sidebar width | Yes | Yes | Not yet | |
| Sidebar density, title mode, path line, search box | Yes | Yes | Not yet | `sidebarDensity`, `sidebarTitleMode`, `sidebarShowPath`, `sidebarShowSearch` |

## Settings, updates and packaging

| Feature | Windows | macOS | Linux | Notes |
|---|---|---|---|---|
| Full settings window with its own navigation | Yes | Yes | Not yet | |
| Plain `settings.json` with the same keys on both platforms | Yes | Yes | Not yet | `%LOCALAPPDATA%\Zharp` on Windows, `~/Library/Application Support/Zharp` on macOS |
| Rebindable keyboard shortcuts in Settings | Yes | Yes | Not yet | Action ids match across platforms, so a settings file moves between them |
| Error log written next to the settings | Yes | Yes | Not yet | `error.log` |
| First run onboarding | Yes | Yes | Not yet | |
| Background update check with a notification | Yes | Yes | Not yet | |
| In place upgrade from inside the app | Yes | Partial | Not yet | Windows runs the silent installer and relaunches; macOS offers the download, since macOS apps are not replaced in place |
| Signed and notarized builds | Not yet | Not yet | Not yet | The Windows installer is unsigned and the macOS build is ad hoc signed, so both show a first launch warning. See the README for the exact steps |
| Package manager entry | Not yet | Not yet | Not yet | The winget manifest and the release automation are written, but `Zharp.Zharp` has not been submitted to winget-pkgs yet, so there is nothing to install from |
