# Zharp

Zharp is a terminal emulator. It runs your normal shell (PowerShell, cmd, zsh,
bash, fish) in a window that treats each command and its output as a thing you
can point at, jump to, collapse and copy, instead of one endless wall of text.

It is native on each platform: C# and WinUI 3 on Windows, Swift and AppKit on
macOS, with a shared terminal engine ported line for line between them so the
two behave the same. There is no web view and no bundled browser.

Both apps are at **0.15.0**. This is beta software: it is used daily, but the
1.0 label is not on it yet.

## Features

- **Command blocks.** Every command you run and the output it produced is one
  addressable block. Jump to the previous or next one with a keystroke, collapse
  a noisy build down to a single line, and copy the command, the output, the
  whole block, or a Markdown fenced version of it. You can search inside a single
  block, with match case and regex.
- **Agent status in the tab.** When a session is running an AI coding tool
  (Claude Code, Codex, Gemini CLI, OpenCode, Aider), the tab card swaps to that
  tool's logo and shows a live status line, so you can see which of your six
  tabs is still thinking and which one is waiting on you.
- **Command history panel.** Press Arrow Up on an empty prompt and a panel opens
  listing what you have actually run, across shells and across sessions, with the
  folder each command ran in and how long ago. Arrow through it and the
  highlighted entry is typed at the prompt live.
- **Tabs you can throw around.** Sessions live in a sidebar (or a compact top
  strip, your choice). Drag a tab to reorder it, drop it on another Zharp window
  to hand it over with its shell still running, or drop it in empty space to tear
  it out into a window of its own.
- **Tabs that say what they are doing.** Each card shows the last command it ran
  and its live working directory, updated as you `cd` around.
- **Themes.** Nine of them, from cream and paper through dark, navy, tokyo,
  dracula, catppuccin and gruvbox. Themes apply live to both the terminal and the
  window chrome, with adjustable background blur and opacity.
- **Shell integration.** Zharp injects a prompt hook for zsh, bash, fish and
  PowerShell so it knows where each command starts and ends (OSC 133) and which
  directory you are in (OSC 7). Nothing to install, no plugin to add to your
  rc file.
- **A real VT emulator, written for this app.** CSI, ESC and OSC parsing,
  24-bit truecolor, alternate screen buffer, scroll regions, DEC line drawing,
  wide CJK characters, bracketed paste, 10,000 lines of scrollback per tab. vim,
  htop, less and tmux behave.
- **Fast text.** GPU composited rendering (Win2D and DirectWrite on Windows,
  Core Text on layer-backed views on macOS), crisp at any DPI or scale factor.
- **Session search.** One keystroke opens a centered palette, type to filter your
  open sessions, Enter to jump.
- **Settings that are just a file.** Everything is stored in a plain
  `settings.json` with the same keys on both platforms, so your configuration
  moves between machines.

Feature coverage is not identical on every platform yet. The honest, per feature
answer is in [docs/parity.md](docs/parity.md).

## Platform support

| Platform | Status | Version | Requirements |
|---|---|---|---|
| Windows | Working | 0.15.0 | Windows 10 version 2004 (build 19041) or newer, 64-bit |
| macOS | Working | 0.15.0 | macOS 13 Ventura or newer |
| Linux | Planned, no code yet | none | The toolkit has not been chosen |

## Install

Every download below comes from the GitHub releases page:

<https://github.com/LupuC/zharp/releases/latest>

### Windows

1. Check your Windows version: press `Win+R`, type `winver`, press Enter. The box
   must say version 2004 or higher, or a build number of 19041 or higher.
2. Download `ZharpSetup.exe` from the releases page above. That file always
   points at the newest build. The version stamped file
   (`ZharpSetup-0.15.0.exe`) is next to it if you want a specific one.
3. Run it. The installer is not code signed yet, so Windows SmartScreen shows a
   blue box that says **"Windows protected your PC"**. Click **More info**, then
   click **Run anyway**. There is no other button that installs it.
4. The install is per user by default, so it does not ask for an administrator
   password. The wizard offers an all users install and a desktop shortcut if
   you want them.
5. Zharp starts when the wizard finishes. Your settings live in
   `%LOCALAPPDATA%\Zharp\settings.json` and survive uninstalling.

If you prefer a package manager:

```powershell
winget install Zharp.Zharp
```

If winget answers `No package found matching input criteria`, the manifest for
that release has not landed in the winget repository yet. Use the installer.

### macOS

Requirements: macOS 13 Ventura or newer. Check with the Apple menu, then
**About This Mac**. Release builds are Intel (x86-64) and run on Apple Silicon
through Rosetta 2; if Rosetta is not installed, macOS offers to install it the
first time you open the app, and you should accept.

1. Download `Zharp.dmg` from the releases page above.
2. Open the `.dmg` and drag **Zharp** into your **Applications** folder.
3. Eject the disk image and open Zharp from Applications.

**The first launch will be refused, and this is expected.** The build is
currently ad hoc signed and not notarized by Apple, so Gatekeeper blocks it.
Recovering from that takes about twenty seconds, but one wrong click deletes
the app, so read this before you double click:

1. A dialog appears saying macOS cannot verify that Zharp is free of malware.
   **The highlighted default button in that dialog moves the app to the Trash.**
   Do not press Return, and do not press Space. Click **Done** instead.
2. Open **System Settings** (Apple menu, then System Settings).
3. Go to **Privacy & Security** in the sidebar.
4. Scroll all the way to the bottom of that pane. Under the Security heading you
   will see a line saying `"Zharp.app" was blocked to protect your Mac`, with an
   **Open Anyway** button next to it. Click **Open Anyway**.
5. Authenticate with Touch ID or your login password.
6. One more dialog appears asking if you are sure. This one has a real
   **Open Anyway** button. Click it.

Zharp opens and keeps opening normally from then on. You only repeat this for a
copy you download later, because macOS re-flags each newly downloaded file.

If you would rather do it in a terminal, this clears the quarantine flag and has
the same effect:

```bash
xattr -dr com.apple.quarantine /Applications/Zharp.app
open /Applications/Zharp.app
```

`xattr` prints nothing when it succeeds. `No such xattr` means the flag was
already gone, which is also fine.

One more system prompt you will see: the first time a shell started by Zharp
touches your Documents, Desktop or Downloads folder, macOS asks for permission.
That prompt comes from macOS, not from Zharp, and every terminal app triggers
it. Allowing it lets your shell read those folders. Denying it limits the shell
only; the terminal keeps working.

Signed and notarized builds are on the roadmap, and this whole section goes away
when they land.

### Linux

Nothing to install yet. `linux/` is an empty placeholder in this repo and no
code has been written for it. The terminal engine is deliberately free of UI
dependencies on both existing platforms, which is the part that makes a third
port realistic.

## Build from source

Full instructions, including the test suites, the commit conventions and how
releases are cut, are in [CONTRIBUTING.md](CONTRIBUTING.md). The short version:

Clone once:

```bash
git clone https://github.com/LupuC/zharp.git
```

**Windows.** Needs the .NET 10 SDK on Windows 10 build 19041 or newer. Check it
with `dotnet --list-sdks`, which must print a line starting with `10.`:

```powershell
cd zharp\windows
dotnet build src\Zharp.App\Zharp.App.csproj -c Release
```

A good build ends with `Build succeeded` and zero errors. Run the result:

```powershell
.\src\Zharp.App\bin\Release\net10.0-windows10.0.22621.0\win-x64\Zharp.exe
```

**macOS.** Needs Swift 5.9 or newer. The Xcode Command Line Tools are enough, a
full Xcode install is not required. Check with `swift --version`, which prints
the version on its first line; if the command is missing, run
`xcode-select --install` and let it finish:

```bash
cd zharp/macos
swift build -c release
.build/release/Zharp
```

A good build ends with `Build complete!`. To get a real bundle you can drag into
Applications:

```bash
make app        # produces dist/Zharp.app
```

## Repo layout

```
zharp/
  windows/    C# / WinUI 3 app. ConPTY, Win2D and DirectWrite rendering.
  macos/      Swift / AppKit app. openpty, Core Text rendering.
  linux/      Placeholder. No code yet, toolkit not chosen.
  shared/     Platform neutral assets used by more than one app.
  docs/       Cross platform docs, including the feature parity matrix.
  .github/    CI and release workflows.
```

Each app directory keeps its own README, CHANGELOG, tests and build tooling, so
you can work on one platform without touching the other. The terminal engine
(`Zharp.Core` on Windows, `ZharpCore` on macOS) has no UI dependencies on either
side, and the two are kept in step deliberately: a change to VT behaviour in one
is expected to land in the other.

## Contributing

Contributions are welcome, including bug reports, and especially a Linux port if
that is your thing. Read [CONTRIBUTING.md](CONTRIBUTING.md) first: it covers the
branch and commit conventions and how to run the tests.

There is no CLA. The project uses the
[Developer Certificate of Origin](https://developercertificate.org/), which
means you certify that you wrote the patch or have the right to submit it, by
signing off your commits:

```bash
git commit -s -m "fix: stop the cursor blinking in the alternate screen"
```

The `-s` adds a `Signed-off-by:` line using your git name and email. Commits
without it will fail the DCO check on the pull request.

## Licence

MIT. See [LICENSE](LICENSE).

Bundled third party assets keep their own licences, listed in full in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md):

- [Tabler Icons](https://tabler.io/icons), MIT, bundled as a subset webfont in
  both apps.
- [DM Mono](https://fonts.google.com/specimen/DM+Mono), SIL Open Font License
  1.1, bundled in the macOS app for the wordmark.
