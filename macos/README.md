# Zharp for macOS

A fast, modern terminal for macOS, built with **Swift / AppKit** and Core Text
rendering on GPU-composited layers.

This is the macOS port of [zharp.app](https://zharp.app) (C# / WinUI 3), kept as
close to 1:1 with the Windows build as the two platforms allow: the same VT
emulator semantics, the same six themes and exact color values, the same
settings keys, the same chrome layout, the same block rendering.

![status](https://img.shields.io/badge/status-early%20preview-orange)

## Features

- **Real pty integration** - hosts any shell (zsh, bash, fish, PowerShell 7, sh)
  through `openpty` + `posix_spawn`, with the child as its own session leader so
  job control, `Ctrl+C`, `Ctrl+Z` and `fg`/`bg` behave exactly as in Terminal.app.
- **Own VT/ANSI emulator** (`ZharpCore`), no WebView, no embedded terminal:
  - CSI / ESC / OSC state-machine parser (VT500-style)
  - 16 / 256 / 24-bit truecolor SGR, bold, italic, underline, strikethrough, inverse
  - Alternate screen buffer (vim, less, htop…), scroll regions, origin mode
  - DEC line-drawing charset, wide (CJK) characters, deferred wrap
  - Bracketed paste, application cursor keys, focus events, device status reports
  - 10 000 lines of scrollback per tab
- **Core Text rendering** on a layer-backed view: batched background/text runs,
  crisp at any scale factor, with box-drawing and block-element characters drawn
  geometrically so TUI borders and bars join seamlessly in any font.
- **Modern chrome, not a classic terminal**: a slim custom title bar (sidebar
  toggle, settings and search buttons beside the traffic lights) over an
  `NSVisualEffectView` backdrop tinted with the theme color.
- **Auto-update** - a background check runs at launch and hourly, raising an
  "Update available" badge in the title bar and posting a notification once per
  release; Settings > About > Check now offers the download.
- **Floating session search** - the title-bar search button (or `⇧⌘F`) opens a
  centered palette: type to filter sessions, arrows + Enter to jump, Esc or
  click-away to dismiss.
- **Interactive blocks** - every command and its output is one addressable
  block: jump between them, collapse a noisy build to a single line, copy the
  command, the output, the whole block or a Markdown-fenced version, and search
  within one block with match-case and regex.
- **Command history** - Arrow Up on an empty prompt opens a sheet docked to the
  input bar listing what you have actually run, across shells and sessions, with
  each entry's folder and age. The highlighted one is typed at the prompt live.
- **Tabs you can throw around** - drag a session card to reorder it, onto
  another Zharp window to hand it over with its shell still running, or into
  empty space to tear it out into a window of its own.
- **Sessions that say what they are doing** - each tab card shows the **last
  command** it ran and its **live working directory**, and swaps to an AI
  agent's own logo and live status line ("✳ Working… (10s)") when it detects
  Claude Code, Codex, Gemini CLI, OpenCode or Aider running in it.
- **Continue where you left off** - reopens the tabs from your last run, same
  shells, same folders.
- **Sessions, not title-bar tabs** - tabs live in a sidebar (vertical cards with
  icon, name and **live current directory**) or a compact top strip,
  switchable in Settings. The cwd comes from OSC 7 reporting; Zharp auto-injects
  a prompt hook for zsh, bash, fish and pwsh so it tracks `cd` in real time.
- **New-tab menu** - the `+` button opens a dropdown: new default terminal
  (default shell at your configured default directory), new terminal at the last
  closed tab's location, or a specific shell - zsh, bash, fish, PowerShell and sh
  entries appear when installed.
- **Mouse selection & clipboard** - drag to select, right-click copies selection
  (or pastes when nothing is selected), trailing whitespace trimmed, soft-wrapped
  lines join without break.
- Scrollback pinning (viewport stays put while output streams), wheel scrolling,
  wheel-to-arrows in full-screen apps.

## Keyboard shortcuts

macOS reserves Control for the shell (`Ctrl+C` must interrupt), so where the
Windows build uses `Ctrl+Shift+…` this one uses Command. Every binding is
rebindable in Settings > Shortcuts, and the action ids match the Windows build,
so a `settings.json` moves between the two.

| Shortcut | Action |
|---|---|
| `⌘T` | New tab (default shell at the default directory) |
| `⌘W` | Close tab |
| `⇧⌘F` | Toggle the floating session search |
| `⌘C` / `⌘V` | Copy selection / paste |
| `⌘B` | Toggle the tab panel |
| `⌘,` | Settings |
| `⌘=` / `⌘-` / `⌘0` | Whole-UI zoom in / out / reset (chrome + terminal) |
| `⌘Wheel` | Font zoom for the current session only |
| `⌘↑` / `⌘↓` | Previous / next command block |
| `⇧⌘O` | Copy the block's output |
| `⇧⌘G` | Find within the block |
| `↑` (empty prompt) | Command history |
| `⌘N` | New window |
| Right click | Copy selection, or paste if none |

Also `⌃Tab` / `⌃⇧Tab` cycle sessions. Everything else (including `Ctrl+C`,
arrows, F-keys, `Option+…`) goes to the shell with correct VT encoding.

## Settings

The gear button opens a full settings page with its own navigation
(Appearance / Terminal / Shell / Shortcuts / About). Changes save immediately to
`~/Library/Application Support/Zharp/settings.json` and apply live where
possible. The keys are the same ones the Windows build writes:

| Key | Values | Meaning |
|---|---|---|
| `theme` | `"cream"` (default) / `"paper"` / `"rose"` / `"dark"` / `"navy"` / `"tokyo"` / `"dracula"` / `"catppuccin"` / `"gruvbox"` | Color theme - applies live to chrome and terminals |
| `backdrop` | `"off"` / `"light"` / `"medium"` / `"strong"` | Background blur strength (the Windows names `"mica"` and `"acrylic"` still load, mapped to the closest macOS material) |
| `backgroundOpacity` | 0.5-1.0 | Chrome and terminal background opacity |
| `tabLayout` | `"sidebar"` / `"top"` | Vertical session cards or horizontal top strip |
| `sidebarDensity` | `"comfortable"` / `"compact"` | Two-line or single-line cards |
| `sidebarTitleMode` | `"shell"` / `"cwd"` | Card's first line: the last command run (or the agent's name), or the working directory |
| `sidebarShowPath` | bool | Show the card's second line |
| `sidebarShowSearch` | bool | Search box above the session list; off shows a "Sessions" label |
| `restoreSessions` | bool | Reopen the tabs you had open when you quit |
| `savedSessions` | array | Tab snapshots (`shell`, `directory`) written on quit |
| `savedActiveIndex` | number | Which saved tab was active |
| `sidebarVisible` | bool | Toggled by the title-bar panel button |
| `fontFamily` | string | Terminal font (applies live) |
| `fontSize` | number | Terminal font size (applies live; ⌘wheel is per-session) |
| `cursorStyle` | `"block"` / `"underline"` / `"bar"` | Default cursor when apps don't pick one |
| `inputPosition` | `"top"` / `"bottom"` / `"pinTop"` | input position: classic, prompt hugs the bottom, or the view anchors to the prompt line |
| `scrollbackLines` | number | History per session (new sessions) |
| `shell` | `"auto"` / `"zsh"` / `"bash"` / `"fish"` / `"pwsh"` / `"sh"` | Default shell; cwd reporting works for all of them |
| `defaultDirectory` | path | Where new terminals start (empty = home); set it in Settings > Shell with the Browse picker |
| `overrideNoColor` | bool | Strip `NO_COLOR` from spawned shells so tools emit ANSI colors (new sessions) |
| `uiZoom` | 0.7-1.5 | Whole-UI zoom (⌘ + =/-/0) |
| `sidebarWidth` | number | Sidebar width; drag its right edge (min 168, max half the window) |

Errors are appended to `~/Library/Application Support/Zharp/error.log`.

UI icons are [Tabler Icons](https://tabler.io/icons) (MIT), bundled as the same
webfont the Windows build ships: subset to the 21 glyphs the app draws and
rebuilt at a 1.25px stroke, so it weighs 9KB instead of 2.8MB and reads lighter
at small sizes. The brand wordmark is set in DM Mono (OFL, bundled).

### Background blur and Reduce transparency

macOS has no Mica or Acrylic, and no blur radius to dial - it has vibrancy
*materials*. Settings > Appearance > Background blur picks between off and three
strengths, backed by the materials that genuinely sample the desktop
(`.sidebar`, `.fullScreenUI`, `.hudWindow`).

If **System Settings > Accessibility > Display > Reduce transparency** is on,
macOS disables vibrancy for every app, and an `NSVisualEffectView` falls back to
a flat panel color. Zharp detects this and renders fully opaque in the exact
theme color rather than letting that fallback tint the theme; the Settings row
says so, and it follows the switch live. Turn Reduce transparency off to get
blur back.

### First launch

macOS asks for permission the first time a shell started by Zharp touches a
protected folder (Documents, Desktop, Downloads). That prompt comes from the
system, not from Zharp - Terminal.app and iTerm2 trigger the same one. Allowing
it lets your shell read those folders; denying it only limits the shell, the
terminal itself keeps working.

## Building

Requires Swift 5.9+ (the Xcode Command Line Tools are enough - no full Xcode
install needed).

```bash
swift build -c release
# run it:
.build/release/Zharp
```

Or through the Makefile:

```bash
make app        # builds dist/Zharp.app, ready to drag into /Applications
make dmg        # packages dist/Zharp-<version>.dmg with a SHA-256 sidecar
```

`make app` compiles a release build, assembles the bundle, generates
`AppIcon.icns` from the shared logo set and signs the result - with a Developer
ID when `MACOS_SIGN_IDENTITY` is set, ad-hoc otherwise.

Builds target this machine's architecture by default. Releases are Intel
(x86-64) only for now, which runs on Apple Silicon through Rosetta 2 - CI
cross-compiles them, since GitHub's macOS runners are Apple Silicon:

```bash
./Scripts/make-app.sh release --arch x86_64               # Intel, what ships
./Scripts/make-app.sh release --arch arm64 --arch x86_64  # universal
```

`--arch` needs a full Xcode install (the Command Line Tools alone do not ship
XCBuild); without one, build natively.

Run the emulator test suite (93 checks, exit code = failures):

```bash
make test
```

The suite covers the VT emulator against the same cases as the Windows
`Zharp.Core.SmokeTests`, plus pty integration checks that run a real `/bin/sh`
and assert its output, colors and `TIOCSWINSZ` resize arrive intact.

## Regenerating the icon font

`Tools/icon-font/` rebuilds the bundled Tabler subset at a 1.25px stroke. See
its README; the font is committed, so this is only needed when adding a glyph.

## Releasing

Releases are automated end to end - see [CONTRIBUTING.md](CONTRIBUTING.md).
Conventional commits on `main` drive a release-please PR; merging it tags
`vX.Y.Z` and publishes a GitHub release, which triggers a workflow that runs the
tests, builds the disk image and attaches `Zharp-<version>.dmg`, its SHA-256 and
a stable `Zharp.dmg`. The website serves that asset from
`/download?platform=macos`, and the in-app update check reads
`/api/version?platform=macos`.

## Architecture

```
Sources/
  ZharpCore/             pure Swift, no UI dependencies
    Pty/PseudoTerminal   openpty + posix_spawn pty host (the ConPTY counterpart)
    Terminal/
      VtParser           escape-sequence state machine → VtHandler actions
      TerminalEmulator   executes VT actions; owns buffers, cursor, modes
      ScreenBuffer       cell grid + scrollback + scroll regions + resize
      Cell               packed cell / color / line model
      Palette            256-color palette + attribute resolution (Campbell)
      TerminalInput      key → VT sequence encoding
      CharWidth          wcwidth (zero-width / wide code points)
      Utf8Decoder        incremental UTF-8 across read boundaries
  ZharpApp/              AppKit shell
    Views/TerminalView   Core Text renderer + input translation
    Views/BoxDrawing     geometric box-drawing / block elements
    Views/BlockModel     block boundaries and text extraction
    Views/TerminalView+  blocks, history sheet, input routing
    HistoryStore         cross-shell command history
    Views/TabDragController  reorder, hand-off and tear-out
    TerminalSession      pty ⇄ emulator pump
    Views/MainWindow…    title bar, sidebar, top strip, shell discovery
Tests/
  ZharpCoreSmokeTests/   deterministic emulator + pty tests
```

Threading model: a background reader thread feeds pty output into the emulator
under `emulator.syncRoot`; the renderer takes the same lock during draw; view
invalidation is coalesced so heavy output never floods the main queue.

### Differences from the Windows build

Everything that could be kept identical was. These are the places where the
platform forced a choice:

| Windows | macOS | Why |
|---|---|---|
| ConPTY (`CreatePseudoConsole`) | `openpty` + `posix_spawn` | Native pty API |
| Win2D / DirectWrite | Core Text on a layer-backed view | Native GPU-composited text |
| Mica / Acrylic backdrop | Background blur: off / light / medium / strong | macOS has no Mica or Acrylic, and no blur-radius knob - only `NSVisualEffectView` materials, so the setting is expressed in macOS terms |
| Custom caption buttons on the right | Native traffic lights on the left | macOS window convention; the icon cluster keeps the same order right after them |
| `Ctrl+Shift+…` shortcuts | `⌘…` shortcuts | Control belongs to the shell on macOS |
| PowerShell `prompt` wrapper | `precmd` / `PROMPT_COMMAND` / `fish_prompt` hooks | Same OSC 133;A + OSC 7 reporting, per shell |
| OSC 9;9 cwd (ConEmu convention) | OSC 7 cwd (xterm convention) | Both are parsed; OSC 7 is what Unix shells emit |
| `%LOCALAPPDATA%\Zharp` | `~/Library/Application Support/Zharp` | Platform data directory |
| Inno Setup silent upgrade | Download page for the new `.app` | macOS apps are not replaced in place |

## Roadmap

- Text reflow on resize; double-click word selection; search in scrollback
- Mouse reporting to applications (SGR 1006), OSC 8 hyperlinks, OSC 52 clipboard
- Panes/splits, command palette, shell integration marks beyond OSC 133;A
- Ligatures & font fallback tuning, sixel/iTerm image protocol
- Signed and notarized `.dmg` distribution
