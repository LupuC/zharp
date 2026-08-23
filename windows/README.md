# Zharp

A fast, modern terminal for Windows, built with **C# / WinUI 3** and GPU-accelerated
text rendering (Win2D / DirectWrite).

![status](https://img.shields.io/badge/status-early%20preview-orange)

## Features

- **Real ConPTY integration** - hosts any shell (PowerShell 7, Windows PowerShell,
  cmd, WSL) through the Windows pseudoconsole API.
- **Own VT/ANSI emulator** (`Zharp.Core`), no WebView, no conhost window:
  - CSI / ESC / OSC state-machine parser (VT500-style)
  - 16 / 256 / 24-bit truecolor SGR, bold, italic, underline, strikethrough, inverse
  - Alternate screen buffer (vim, less, htop…), scroll regions, origin mode
  - DEC line-drawing charset, wide (CJK) characters, deferred wrap
  - Bracketed paste, application cursor keys, focus events, device status reports
  - 10 000 lines of scrollback per tab
- **GPU rendering** with Win2D: batched background/text runs, crisp at any DPI.
- **Modern chrome, not a classic terminal**: a slim custom title bar (sidebar
  toggle, settings and search buttons next to custom caption buttons) on a
  neutral dark-grey Mica surface.
- **Auto-update** - a background check toasts a Windows notification when a
  new version ships; Settings > About > Check now downloads it and upgrades
  in place (silent installer, relaunches when done).
- **Floating session search** - the title-bar search button (or `Ctrl+Shift+F`)
  opens a centered palette: type to filter sessions, arrows + Enter to jump,
  Esc or click-away to dismiss.
- **Sessions, not title-bar tabs** - tabs live in a sidebar (vertical cards with
  icon, shell name and **live current directory**) or a compact top strip,
  switchable in Settings. The cwd comes from OSC 9;9 / OSC 7 reporting; Zharp
  auto-injects a PowerShell prompt hook so it tracks `cd` in real time (the
  shell's raw OSC title is kept as a tooltip only).
- **New-tab menu** - the `+` button opens a dropdown: new default terminal (default
  shell at your configured default directory), new terminal at the last closed
  tab's location, or a specific shell - PowerShell 7, Windows PowerShell, cmd,
  Git Bash and WSL entries appear when installed.
- **Mouse selection & clipboard** - drag to select, right-click copies selection
  (or pastes when nothing is selected), trailing whitespace trimmed, soft-wrapped
  lines join without break.
- Scrollback pinning (viewport stays put while output streams), wheel scrolling,
  wheel-to-arrows in full-screen apps.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+T` | New tab (default shell at the default directory) |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Shift+F` | Toggle the floating session search |
| `Ctrl+Shift+C` / `Ctrl+Insert` | Copy selection |
| `Ctrl+Shift+V` / `Shift+Insert` | Paste |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | Whole-UI zoom in / out / reset (chrome + terminal) |
| `Ctrl+Wheel` | Font zoom for the current session only |
| Right click | Copy selection, or paste if none |

Also `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle sessions. Everything else (including
`Ctrl+C`, arrows, F-keys, `Alt+…`) goes to the shell with correct VT encoding.

## Settings

The gear button opens a full settings window with its own navigation
(Appearance / Terminal / Shell / About). Changes save immediately to
`%LOCALAPPDATA%\Zharp\settings.json` and apply live where possible:

| Key | Values | Meaning |
|---|---|---|
| `theme` | `"cream"` (default) / `"dark"` | Color theme - Cream follows the logo (charcoal on cream), applies live to chrome and terminals |
| `tabLayout` | `"sidebar"` / `"top"` | Vertical session cards or horizontal top strip |
| `sidebarVisible` | bool | Toggled by the title-bar panel button |
| `fontFamily` | string | Terminal font (applies live) |
| `fontSize` | number | Terminal font size (applies live; Ctrl+wheel is per-session) |
| `cursorStyle` | `"block"` / `"underline"` / `"bar"` | Default cursor when apps don't pick one |
| `inputPosition` | `"top"` / `"bottom"` / `"pinTop"` | Input position: classic, prompt hugs the bottom, or the view anchors to the prompt line (applies live; full-screen apps unaffected) |
| `scrollbackLines` | number | History per session (new sessions) |
| `shell` | `"auto"` / `"pwsh"` / `"powershell"` / `"cmd"` | Default shell; cwd reporting works for all of them |
| `defaultDirectory` | path | Where new terminals start (empty = user folder); set it in Settings > Shell with the Browse picker |
| `overrideNoColor` | bool | Strip `NO_COLOR` from spawned shells so tools emit ANSI colors (new sessions) |
| `uiZoom` | 0.7-1.5 | Whole-UI zoom (Ctrl + +/-/0) |
| `sidebarWidth` | number | Sidebar width; drag its right edge (min 168, max half the window) |

Errors are appended to `%LOCALAPPDATA%\Zharp\error.log`.

UI icons are [Tabler Icons](https://tabler.io/icons) (MIT), bundled as a webfont.

## Building

Requires the .NET 10 SDK on Windows 10 19041+.

```powershell
dotnet build src/Zharp.App/Zharp.App.csproj -c Release
# run it:
.\src\Zharp.App\bin\Release\net10.0-windows10.0.22621.0\win-x64\Zharp.exe
```

## Installer

A self-contained setup (no .NET required on the target machine) is built with
[Inno Setup 6](https://jrsoftware.org/isinfo.php):

```powershell
dotnet publish src/Zharp.App/Zharp.App.csproj -c Release -r win-x64 --self-contained true -p:BaseOutputPath=bin\pub\
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer\zharp.iss
# result: installer\Output\ZharpSetup-<version>.exe
```

The installer defaults to a per-user install (no admin prompt) with optional
desktop shortcut; uninstalling keeps your settings in `%LOCALAPPDATA%\Zharp`.
On first launch Zharp shows a short onboarding (theme pick + key shortcuts);
it reappears only if `onboarded` is removed from settings.json.

Run the emulator test suite (64 checks, exit code = failures):

```powershell
dotnet run --project tests/Zharp.Core.SmokeTests
```

## Architecture

```
src/
  Zharp.Core/            pure .NET, no UI dependencies
    Pty/ConPty.cs        Windows pseudoconsole host (CreatePseudoConsole P/Invoke)
    Terminal/
      VtParser.cs        escape-sequence state machine → IVtHandler actions
      TerminalEmulator.cs executes VT actions; owns buffers, cursor, modes
      ScreenBuffer.cs    cell grid + scrollback + scroll regions + resize
      Cell.cs            packed cell / color / line model
      Palette.cs         256-color palette + attribute resolution (Campbell)
      TerminalInput.cs   key → VT sequence encoding
      CharWidth.cs       wcwidth (zero-width / wide code points)
  Zharp.App/             WinUI 3 shell
    Controls/TerminalView.cs  Win2D renderer + input translation
    TerminalSession.cs   ConPty ⇄ emulator pump
    MainWindow.xaml(.cs) TabView chrome, Mica, shell discovery
tests/
  Zharp.Core.SmokeTests/ deterministic emulator tests
```

Threading model: a background reader thread feeds PTY output into the emulator
under `Emulator.SyncRoot`; the renderer takes the same lock during draw; UI
invalidation is coalesced so heavy output never floods the dispatcher.

Note: PowerShell 7.2+ honors a global `NO_COLOR` environment variable by
stripping ANSI colors from its own output - if colors seem missing, check
`$env:NO_COLOR` (PSReadLine syntax highlighting shows regardless).

## Roadmap

- Settings (profiles, schemes, font) via `settings.json`
- Text reflow on resize; double-click word selection; search in scrollback
- Mouse reporting to applications (SGR 1006), OSC 8 hyperlinks, OSC 52 clipboard
- Panes/splits, command palette, shell integration marks (OSC 133)
- Ligatures & font fallback tuning, sixel/iTerm image protocol
