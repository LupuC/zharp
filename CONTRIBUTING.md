# Contributing to Zharp

Zharp is a terminal emulator. It runs your shell, but it also understands what is
going on inside it: commands and their output are grouped into blocks you can
scroll, fold and copy as a unit, there is a status indicator for AI coding tools
so you can see when one is waiting on you, a searchable command history panel,
tabs you can drag to reorder or tear out into a new window, themes, and shell
integration built on the OSC 133 and OSC 7 escape sequences.

There are two apps in this repository. The Windows app is C# on WinUI 3, the
macOS app is Swift on AppKit. They are separate codebases that implement the same
product, and each one carries its own port of the terminal engine.

Contributions are welcome: bug reports, fixes, features, docs, themes, or just
telling us that something is confusing. You do not need to know both codebases.
Picking one platform and staying in it is completely fine, and the checkout
instructions below let you download only that half of the repository.

Zharp is pre-1.0 and moving quickly, so if you are planning something large,
open an issue first and describe it. That saves you from building something that
collides with work already in flight.

---

## Table of contents

1. [Getting the code](#getting-the-code)
2. [Repository layout](#repository-layout)
3. [Building on Windows](#building-on-windows)
4. [Building on macOS](#building-on-macos)
5. [Linux](#linux)
6. [Commit messages](#commit-messages)
7. [Sign your commits (DCO)](#sign-your-commits-dco)
8. [What CI runs on a pull request](#what-ci-runs-on-a-pull-request)
9. [Features land on every platform at once](#features-land-on-every-platform-at-once)
10. [Opening a pull request](#opening-a-pull-request)
11. [Things you should never edit by hand](#things-you-should-never-edit-by-hand)

---

## Getting the code

You need Git 2.27 or newer. Check it:

```bash
git --version
```

Expected output: `git version 2.27.0` or higher. If it is older, the sparse
checkout route below will not work, and you should use the full clone.

### The normal way: clone everything

```bash
git clone git@github.com:LupuC/zharp.git
cd zharp
```

That gives you both apps and all the assets. This is what almost everyone
should do: the repository starts at the 0.16.0 consolidation rather than at
either app's first commit, so a full clone is only a few megabytes and takes a
second or two.

If you have not set up an SSH key with GitHub, use HTTPS instead:

```bash
git clone https://github.com/LupuC/zharp.git
cd zharp
```

### The lean way: sparse checkout of one platform

This is not about download size, which is small either way. It is about not
having the other platform's app in your editor's file tree, its search results
and its grep output while you work. If you only ever intend to touch the macOS
app, run this instead:

```bash
git clone --filter=blob:none --sparse git@github.com:LupuC/zharp.git
cd zharp && git sparse-checkout set macos shared
```

For the Windows app, swap the last argument:

```bash
git clone --filter=blob:none --sparse git@github.com:LupuC/zharp.git
cd zharp && git sparse-checkout set windows shared
```

What those two flags actually do:

* `--filter=blob:none` makes it a *partial clone*. Git downloads the full commit
  history and the directory structure, but not the contents of every file in
  every past commit. File contents are fetched on demand, the first time you
  actually need them. Practically: the clone is much faster and much smaller, and
  the only thing you lose is that some operations touching old revisions (an
  ancient `git blame`, checking out a tag from a year ago) will pause to fetch
  from the network.
* `--sparse` starts you with only the files at the top level of the repository
  checked out, no subdirectories. `git sparse-checkout set macos shared` then
  fills in exactly the directories you name.

Check what you got:

```bash
ls
```

Expected output after `git sparse-checkout set macos shared`: the top level
files (`CONTRIBUTING.md`, `LICENSE`, `README.md` and friends) plus `macos` and
`shared`, with no `windows` directory present.

Always include `shared` in the list. Both apps read assets out of it, and a
checkout without it will look like files are missing.

You are not locked in. Add another directory later:

```bash
git sparse-checkout add windows
```

Or go back to a full checkout:

```bash
git sparse-checkout disable
```

See what is currently checked out:

```bash
git sparse-checkout list
```

One thing to be clear about: sparse checkout is purely a local convenience. It
changes nothing about your commits, your branch, or what CI does. CI always
works on the whole repository.

---

## Repository layout

```
zharp/
├── windows/     the Windows app (C#, WinUI 3, .NET 10)
├── macos/       the macOS app (Swift, AppKit, SwiftPM)
├── linux/       placeholder, empty, no code yet
├── shared/      platform neutral assets used by both apps
├── docs/        documentation that is not specific to one platform
└── .github/     GitHub Actions workflows and issue templates
```

| Directory | What lives there |
|---|---|
| `windows/` | `src/Zharp.Core` (the terminal engine, no UI), `src/Zharp.App` (the WinUI 3 shell), `tests/Zharp.Core.SmokeTests`, `installer/` (the Inno Setup script), `Directory.Build.props`, `version.txt` |
| `macos/` | `Sources/ZharpCore` (the terminal engine, no UI), `Sources/ZharpApp` (the AppKit shell), `Tests/ZharpCoreSmokeTests`, `Scripts/` (icon, bundle and dmg builders), `Packaging/`, `Makefile`, `version.txt` |
| `linux/` | Nothing yet. See [Linux](#linux). |
| `shared/` | Icons, fonts, logos and other assets that both apps ship |
| `docs/` | Cross platform documentation |
| `.github/` | Workflow definitions. GitHub Actions only reads workflows from the repository root, so everything CI does lives here, not under the platform directories. |

### Warning about `shared/`

**A pull request that touches anything under `shared/` triggers every
platform's CI, not just the one you were thinking about.** Those files are
compiled into or copied into both app bundles, so a change there can break the
Windows build, the macOS build, or both.

Concretely this means:

* Your PR will run the Windows job on a `windows-latest` runner and the macOS
  job on a `macos-latest` runner, so it takes longer to go green.
* If you replace an asset, check both apps still build. The macOS CI job asserts
  hard facts about bundled assets, for example that `tabler-icons.ttf` is under
  64 KB, because the shipped file is a subset of the full icon font and dropping
  the 2.8 MB original in its place would bloat the app. That assertion will fail
  your PR.
* If you only have one platform checked out sparsely, say so in the PR
  description. Someone with the other platform will verify it before merge.

If you can avoid putting a platform specific file in `shared/`, avoid it. Put it
under `windows/` or `macos/` instead.

---

## Building on Windows

Everything in this section is run from a PowerShell prompt in the `windows/`
directory:

```powershell
cd windows
```

### Prerequisites

| What | Version | Why |
|---|---|---|
| Windows | 10 build 19041 or newer, or Windows 11 | The app targets `10.0.19041.0` as its minimum |
| .NET SDK | 10.x | Build, run and test. This is the only hard requirement. |
| Git | 2.27+ | Getting the code |
| Inno Setup | 6 | Optional, only if you want to build the installer |

You do **not** need Visual Studio, the Windows App SDK runtime, MSIX tooling, or
a separate Windows SDK install. The Windows App SDK and Win2D arrive as NuGet
packages during restore, the Windows SDK targeting pack arrives as a NuGet
reference pack, and the app is built unpackaged and self contained. The .NET 10
SDK really is all you need.

Verify your Windows build number:

```powershell
winver
```

A dialog opens. It must say `Version 2004` / `OS Build 19041` or higher (any
current Windows 10 or Windows 11 is fine).

Verify the .NET SDK:

```powershell
dotnet --version
```

Expected output: a version starting with `10.`, for example `10.0.100`. If you
get "command not found" or a `8.x` / `9.x` version, install the .NET 10 SDK from
<https://dotnet.microsoft.com/download/dotnet/10.0> and open a new terminal.

List every SDK you have, if the above is ambiguous:

```powershell
dotnet --list-sdks
```

At least one line must start with `10.`.

Verify Inno Setup (only if you want to build the installer):

```powershell
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" /?
```

Expected output: the Inno Setup 6 command line compiler banner and a usage
listing. If you get "the term ... is not recognized", Inno Setup is either not
installed or is installed system wide, in which case try
`& "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe" /?`. Get it from
<https://jrsoftware.org/isdl.php>.

### Build

```powershell
dotnet build src/Zharp.App/Zharp.App.csproj -c Release
```

The first run restores NuGet packages and takes a few minutes. Success looks
like a summary ending in:

```
Build succeeded.
    0 Warning(s)
    0 Error(s)
```

The binaries land in
`src\Zharp.App\bin\Release\net10.0-windows10.0.22621.0\win-x64\`. The
architecture folder is in the path because the project pins `win-x64`.

To build every project in the repository, including the tests, there is a
solution file:

```powershell
dotnet build Zharp.slnx -c Release
```

### Run

There is no `dotnet run` target for the app. Launch the built executable
directly:

```powershell
.\src\Zharp.App\bin\Release\net10.0-windows10.0.22621.0\win-x64\Zharp.exe
```

Success looks like a Zharp window opening with a shell prompt in it.

### Test

The test suite is a plain console executable, not a test framework. **Its exit
code is the number of failed checks**, which is what makes it usable from CI.

```powershell
dotnet run --project tests/Zharp.Core.SmokeTests -c Release
```

Success looks like a single line:

```
All 89 checks passed.
```

and an exit code of 0. Check the exit code explicitly if you are unsure:

```powershell
dotnet run --project tests/Zharp.Core.SmokeTests -c Release
echo $LASTEXITCODE
```

Expected output: `0`.

A failure prints each failed check and then a summary line like
`3 FAILED, 86 passed.`, and exits with `3`. The check count grows as tests are
added, so do not treat the number 89 as fixed. What matters is the word `All`
and the exit code.

Add new checks next to the existing ones in
`tests/Zharp.Core.SmokeTests/Program.cs`. Anything you change in `Zharp.Core`
should come with a check.

Run the tests and the build before you push. That is exactly what CI does.

### Build the installer (optional)

Two steps, and the publish flags matter because the Inno Setup script has the
output path hardcoded:

```powershell
dotnet publish src/Zharp.App/Zharp.App.csproj -c Release -r win-x64 --self-contained true -p:BaseOutputPath=bin\pub\
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer\zharp.iss
```

Success: `installer\Output\ZharpSetup-<version>.exe` exists. If ISCC complains it
cannot find source files, you changed `BaseOutputPath` and it no longer matches
the `PublishDir` define at the top of `installer/zharp.iss`.

Do not change `AppId` in `installer/zharp.iss`. Upgrade detection and the package
manager manifest both key off that GUID, and changing it would leave existing
installs orphaned.

### Debug environment variables

Useful when you are chasing something specific. Set them before launching
`Zharp.exe`:

| Variable | Effect |
|---|---|
| `ZHARP_DUMP_PTY=<file>` | Write every byte read from the pty to `<file>` |
| `ZHARP_DEBUG_TABS=1` | Log tab drag, reorder and tear-out events |
| `ZHARP_DEBUG_HISTORY=1` | Log command history panel behaviour |
| `ZHARP_FAKE_UPDATE=1` | Pretend an update is available, to test the updater UI |
| `ZHARP_TEST_ZOOM=1` | Force the zoom test path |
| `ZHARP_TEST_GHOST=1` | Force the drag ghost test path |
| `ZHARP_TEST_TEAROFF=1` | Force the tab tear-off test path |
| `ZHARP_TEST_SETTINGS=1` | Force the settings test path |

For example:

```powershell
$env:ZHARP_DUMP_PTY = "$env:TEMP\pty.log"
.\src\Zharp.App\bin\Release\net10.0-windows10.0.22621.0\win-x64\Zharp.exe
```

---

## Building on macOS

Everything in this section is run from a terminal in the `macos/` directory:

```bash
cd macos
```

### Prerequisites

| What | Version | Why |
|---|---|---|
| macOS | 13.0 or newer | The app's minimum system version, and the build host |
| Xcode Command Line Tools | Swift 5.9 or newer | Build, run, test, package |
| `python3`, `zsh`, `bash` | Any recent version | The shell template syntax checker |
| Full Xcode | Any recent version | Optional, only needed to cross compile or build a universal binary |

A full Xcode install is **not** required for normal development. The Command Line
Tools are enough.

Verify your macOS version:

```bash
sw_vers
```

Expected output includes `ProductVersion:` followed by `13.` or higher.

Verify the Command Line Tools and Swift:

```bash
xcode-select -p
swift --version
```

Expected output: a path (either `/Library/Developer/CommandLineTools` or a path
inside `Xcode.app`), then a Swift banner reporting `Apple Swift version 5.9` or
higher. If `xcode-select -p` errors, install the tools:

```bash
xcode-select --install
```

A system dialog appears, accept it and wait for the download to finish, then
re-check.

Verify the tools the shell template check needs:

```bash
python3 --version
zsh --version
bash --version
```

Expected output: a Python 3.x version, a zsh version (5.x), and a bash version
(macOS ships 3.2.57, which is fine). All three ship with macOS, so this should
just work.

Verify the packaging tools (all part of a base macOS install):

```bash
which iconutil hdiutil lipo codesign shasum
```

Expected output: five paths, one per line, no "not found".

Optional, only if you plan to build a universal or cross architecture binary:

```bash
xcodebuild -version
```

Expected output: `Xcode 15.0` or similar. If you get
`tool 'xcodebuild' requires Xcode`, you have Command Line Tools only. That is
fine for everything except `--arch`, because SwiftPM's multi architecture build
path needs the full Xcode build system.

### Build

```bash
make build
```

This runs `swift build`. The first build compiles everything from scratch and
takes around two minutes. Success looks like:

```
Build complete! (119.65s)
```

and a binary at `.build/debug/Zharp`.

For an optimized build:

```bash
make release
```

That runs `swift build -c release`. Note the name is a little misleading: it
compiles with optimizations, it does not package or publish anything.

### Run

```bash
make run
```

That builds in debug and launches `.build/debug/Zharp` directly. Success is a
Zharp window with a shell prompt in it. Two things are missing from this raw
binary because it is not inside an app bundle: there is no icon, and the version
reported in the UI falls back to a literal in the source instead of coming from
the bundle's `Info.plist`. Both are expected.

To run the real thing, build a bundle:

```bash
make app
open dist/Zharp.app
```

`make app` builds in release, generates the icon, assembles `dist/Zharp.app` and
signs it. Success ends with lines like:

```
==> Ad-hoc signed
==> Done: dist/Zharp.app (x86_64)
```

"Ad-hoc signed" is correct and expected locally. Developer ID signing and
notarization only happen in the release workflow, with secrets that are not
available to you. macOS will complain the first time you open a locally built
bundle: right click the app and choose Open, then confirm.

### Test

```bash
make test
```

That does two things: it syntax checks the zsh and bash shell integration
templates that are embedded as string constants in
`Sources/ZharpApp/ShellDiscovery.swift`, then it runs the smoke test suite. Like
the Windows suite it is a plain executable, **its exit code is the number of
failed checks**, and it deliberately does not use XCTest so it can run without a
full Xcode install.

Success looks like:

```
==> zsh template OK
==> bash template OK
All 120 checks passed.
```

Check the exit code explicitly if you want to be sure:

```bash
make test; echo $?
```

Expected output: `0`.

The check count grows as tests are added, so do not treat 120 as fixed. What
matters is `All ... passed.` and the exit code.

You can run either half on its own:

```bash
./Scripts/check-shell-templates.sh
swift run -c release ZharpCoreSmokeTests
```

The second one is exactly what CI runs, in release configuration. `make test`
uses the debug build, which is faster to iterate on.

`swift test` will do nothing useful here. There is no XCTest target, on purpose.

Add new checks next to the existing ones in `Tests/ZharpCoreSmokeTests/main.swift`:

```swift
check(rowText(e, 0) == "hello", "print basic text")
```

### All the Makefile targets

| Target | What it does |
|---|---|
| `make build` | Debug build into `.build/debug/` |
| `make release` | Optimized build into `.build/release/`, no packaging |
| `make run` | Build debug, then launch the raw unbundled binary |
| `make test` | Shell template check, then the smoke suite (exit code = failures) |
| `make check-shell` | Just the zsh and bash template syntax check |
| `make icon` | Render `Packaging/AppIcon.icns` from the 1024px source art |
| `make app` | `dist/Zharp.app` from the release build |
| `make app-debug` | `dist/Zharp.app` from the debug build |
| `make dmg` | `dist/Zharp-<version>.dmg` plus a `.sha256` sidecar |
| `make clean` | `rm -rf .build dist` |

Note that `make clean` leaves the generated `Packaging/AppIcon.icns` behind.
Delete it by hand if you want a truly clean tree. It is gitignored either way.

### Architecture

The shipped macOS build is Intel (`x86_64`), and runs on Apple Silicon through
Rosetta. That is what CI builds and verifies:

```bash
./Scripts/make-app.sh release --arch x86_64
```

On an Intel Mac, a plain `make app` already produces `x86_64`, so you do not
need the flag. On an Apple Silicon Mac, a plain `make app` produces `arm64`,
which is fine for local development but is not what ships. Passing `--arch`
requires a full Xcode install. To build a universal binary:

```bash
./Scripts/make-app.sh release --arch arm64 --arch x86_64
```

Confirm what you built:

```bash
lipo -archs dist/Zharp.app/Contents/MacOS/Zharp
```

Expected output: `x86_64`, or `x86_64 arm64` for a universal build.

---

## Linux

There is no Linux code yet. The `linux/` directory is an empty placeholder so
that the repository layout is honest about where it will go.

The technology choice is genuinely still open. Nothing has been decided about
the toolkit, the language, or how much of the terminal engine gets ported versus
rewritten. If you have strong opinions or, better, want to build it, open an
issue and let us talk about it before writing a lot of code. This is the single
biggest open contribution in the project.

Two things that will constrain whatever gets chosen:

* The terminal engine already exists twice, once in C# and once in Swift, and
  the two are kept in step check for check by their smoke test suites. Whatever
  the Linux port does, the same suite of behaviours has to pass.
* The shell integration protocol (OSC 133 for command marks, OSC 7 for the
  working directory) is the contract between the shell and the app. That part is
  platform neutral and should be reused, not reinvented.

---

## Commit messages

Every commit message follows [Conventional Commits](https://www.conventionalcommits.org).
This is not a style preference. Release automation parses these messages to
decide the next version number and to write the changelog, so the prefix you
choose has a real, mechanical effect.

The format:

```
<type>(<optional scope>): <short description>

<optional body>

<optional footers>
```

The scope is optional but helpful in a repository with two apps. Use `windows`,
`macos`, `shared`, `docs` or `ci`.

### Types and what they do to the version

Zharp is pre-1.0, and the release tooling is configured so that breaking changes
bump the minor version rather than the major one while the version is still
`0.x`. The version that moves is the one for the platform directory your
commit touches. Assuming that platform is on `0.16.0`:

| Prefix | Meaning | Next version | Shows in changelog |
|---|---|---|---|
| `feat:` | A new feature | `0.17.0` (minor) | Yes, under Features |
| `fix:` | A bug fix | `0.16.1` (patch) | Yes, under Bug Fixes |
| `perf:` | A performance improvement | `0.16.1` (patch) | Yes |
| `refactor:` | A change with no behaviour change | `0.16.1` (patch) | Yes |
| `docs:` | Documentation only | no release | No |
| `chore:` | Tooling, dependencies, housekeeping | no release | No |
| `test:` | Tests only | no release | No |
| `ci:` | Workflow changes | no release | No |
| `feat!:` or a `BREAKING CHANGE:` footer | An incompatible change | `0.17.0` (minor, because we are pre-1.0) | Yes, called out at the top |

If a release contains only `docs:` and `chore:` commits, no release happens at
all. That is intentional, and it is why picking the right prefix matters more
than it looks.

### Real examples

A new feature:

```bash
git commit -s -m "feat: add a command history panel opened with the up arrow"
```

A feature scoped to one platform:

```bash
git commit -s -m "feat(macos): remember window size and position between launches"
```

A bug fix, with a body explaining the cause:

```bash
git commit -s -m "fix: keep the cursor visible when the pane is scrolled to the bottom" \
  -m "The scroll offset was being recomputed after the cursor row was clamped, so a resize during output could park the cursor one row below the viewport."
```

Documentation, which will not cause a release:

```bash
git commit -s -m "docs: explain the sparse checkout route in CONTRIBUTING"
```

Housekeeping, which will also not cause a release:

```bash
git commit -s -m "chore: bump the Win2D dependency to 1.4.0"
```

A breaking change. Both the `!` and the footer work, and using both is clearest:

```bash
git commit -s -m "feat(shared)!: rename the theme file format keys to snake_case" \
  -m "BREAKING CHANGE: existing theme files under the old camelCase keys no longer load and have to be regenerated. Run the migration in docs/themes.md."
```

### Rules of thumb

* One logical change per commit. If you cannot describe it in one line, it is
  probably two commits.
* Write the subject in the imperative mood, as a command: "add", "fix",
  "remove", not "added" or "fixes".
* Keep the subject under about 72 characters. Put the detail in the body.
* Do not put a period at the end of the subject.
* If your commit fixes a reported issue, add a footer: `Fixes #123`.

If you get a prefix wrong before pushing, fix it:

```bash
git commit --amend -m "fix: the message you actually meant"
```

If you have already pushed, and your branch is not shared with anybody:

```bash
git commit --amend -m "fix: the message you actually meant"
git push --force-with-lease
```

Use `--force-with-lease`, never a plain `--force`. It refuses to overwrite work
you have not seen.

---

## Sign your commits (DCO)

Zharp uses the [Developer Certificate of Origin](https://developercertificate.org)
version 1.1. There is no CLA, you do not sign anything, and you do not assign
your copyright to anybody. You keep it.

In plain words, adding a sign-off to a commit is you stating three things: that
you wrote the code yourself, or that you have the right to submit it under the
project's MIT licence; that you understand the contribution is public and will be
kept indefinitely in the repository's history; and that you are fine with it
being redistributed under that licence. That is the whole thing. It exists so
that the project has a clear, on-the-record chain of provenance for every line of
code in it.

Mechanically, the sign-off is one trailer line at the end of the commit message:

```
Signed-off-by: Jane Doe <jane@example.com>
```

Git adds that line for you when you pass `-s`:

```bash
git commit -s -m "fix: something"
```

The name and address come from your Git configuration, so set those once before
your first commit:

```bash
git config --global user.name "Jane Doe"
git config --global user.email "jane@example.com"
```

Check what is currently configured:

```bash
git config user.name
git config user.email
```

Expected output: your name, then your email address. If either is blank, the
sign-off will be wrong or the commit will be refused.

If you do not want your real address in a public commit history, use the noreply
address GitHub gives you. Find it under Settings, Emails, "Keep my email
addresses private". It looks like `12345678+jane@users.noreply.github.com`. Use
that as your `user.email` and everything works normally.

Verify a sign-off actually landed:

```bash
git log -1 --format=%B
```

Expected output: your commit message, then a blank line, then the
`Signed-off-by:` line.

### Fixing a commit that forgot the sign-off

For the most recent commit:

```bash
git commit --amend -s --no-edit
```

`--no-edit` keeps the message exactly as it was, `-s` adds the missing trailer.
If you already pushed that commit:

```bash
git commit --amend -s --no-edit
git push --force-with-lease
```

If several commits on your branch are missing sign-offs, sign all of them at
once. From your branch, with `main` up to date:

```bash
git fetch origin
git rebase --signoff origin/main
git push --force-with-lease
```

That rewrites every commit on your branch that is not already on `main`, adding
the trailer to each one. This needs Git 2.30 or newer for `--signoff` on
`rebase`. Check with `git --version` if it errors out.

There is a DCO check on pull requests. It fails loudly and tells you exactly
which commits are unsigned, so you cannot miss it. It is easy to fix and nobody
minds, but do it before asking for a review.

---

## What CI runs on a pull request

The workflows live in `.github/workflows/` at the repository root. Four of them
matter to you as a contributor: the Windows build, the macOS build, the DCO
check and the version line check. The release workflows never run on a pull
request.

**Only the platforms you touched get built.** The jobs have path filters on
them, so a PR that changes only Swift files under `macos/` does not spin up a
Windows runner, and vice versa. A PR that touches `shared/` runs both, as does a
PR that touches the workflow files themselves.

### The Windows job

Runs on a `windows-latest` runner:

1. Check out the repository.
2. Install the .NET 10 SDK.
3. Run the smoke tests:
   `dotnet run --project tests/Zharp.Core.SmokeTests -c Release`
4. Build the app:
   `dotnet build src/Zharp.App/Zharp.App.csproj -c Release`

### The macOS job

Runs on a `macos-latest` runner, which is Apple Silicon:

1. Check out the repository.
2. Print `swift --version`.
3. Run the shell template syntax check: `./Scripts/check-shell-templates.sh`
4. Run the smoke tests: `swift run -c release ZharpCoreSmokeTests`
5. Build the app bundle: `./Scripts/make-app.sh release --arch x86_64`
6. Verify the bundle. This step is a list of hard assertions, and it is the one
   that catches asset mistakes: the executable, `Info.plist` and `AppIcon.icns`
   exist; `tabler-icons.ttf`, `DMMono-Medium.ttf`, `logo-cream.png` and
   `logo-ink.png` are present in `Contents/Resources`; the icon font is under
   64 KB; the nested SwiftPM resource bundle has been unpacked;
   `codesign --verify --deep --strict` passes; the version in `Info.plist`
   matches `version.txt`; and `lipo -archs` reports exactly `x86_64`.

### The DCO check

Runs on every pull request, on an Ubuntu runner, and takes a couple of seconds.
It walks every commit your branch adds and fails if one of them has no
`Signed-off-by:` trailer matching that commit's author email. Merge commits are
skipped, because git writes those. Bot commits are skipped, because
release-please's own release commit has no sign-off and could never get one.

The failure message includes the two commands that fix it, so you do not need
to come back here.

### The version line check

Runs on every pull request and takes a couple of seconds. It reads
`windows/version.txt` and `macos/version.txt` and fails if they disagree on
`major.minor`.

Zharp ships one line across every platform, and the patch underneath it belongs
to a single platform's bug fixes. Windows on 0.16.2 while macOS is on 0.16.0 is
correct and passes. Windows on 0.16.2 while macOS is on 0.17.0 is drift and
fails, because a feature moved one platform's line without the other.

You will normally only see this on a release pull request, or if you edited a
version file by hand, which you should not.

### What CI does not do

* It does not upload build artifacts. There is no downloadable installer or dmg
  from a pull request. If a reviewer needs to try your change, they build it.
* It does not sign anything. The bundle CI builds is ad-hoc signed, and it is
  not notarized.
* There is no linter or formatter check. Match the style of the file you are
  editing.
* Nothing builds ARM64 on Windows, and nothing builds a universal macOS binary.

### The gotcha: a required check that never reports

Path filters and required status checks interact badly, and it will eventually
happen to you. If a check is marked required on `main` but its job is skipped
because your PR did not touch the matching paths, GitHub does not treat that as
"passed". It shows the check as `Expected` with a message like "Waiting for
status to be reported", and the merge button stays blocked forever. Your PR
looks stuck even though everything that ran was green.

Nothing you do on your side will clear it. Specifically:

* Pushing an empty commit will not help.
* Closing and reopening the PR will not help.
* Rebasing will not help.
* Do not add an unrelated file just to make a path filter match. That pollutes
  the diff and the changelog.

What to do: leave a comment on the PR saying which check is stuck. A maintainer
either merges with the administrator override, or fixes the branch protection
configuration so the skipped job reports a neutral success. If it is a check for
a platform you genuinely did not touch, say so, that makes the decision obvious.

---

## Features land on every platform at once

**A feature is not finished until every shipping platform has it.** Read this
before you start writing one, because it changes where you branch from, and
finding out afterwards is expensive.

### Why

Zharp's version has two halves that mean different things:

```
0.19 . 2
 |     `-- the PATCH. One platform's own bug fixes. Windows can be on
 |         0.19.2 while macOS is on 0.19.0: macOS had nothing to fix.
 `-------- the LINE. Every platform is on it. It moves when a feature
           ships, and it moves for all of them together.
```

The line is the promise. "Zharp 0.19" means the same thing whichever platform
you are on, so nobody has to cross-reference a table to find out whether the
thing they read about exists on their machine.

That promise is enforced, not assumed. `.github/workflows/version-line.yml`
fails any pull request whose platforms disagree on `MAJOR.MINOR`. It is a
required check, so it cannot be waved through.

### What that means in practice

Merging a feature that exists on only one platform does not fail anything at
the time. The wall comes later:

1. Your macOS-only `feat:` merges to `main`. Nothing complains.
2. release-please opens a release pull request bumping **macOS alone** to
   0.19.0, leaving Windows on 0.18.x.
3. `version-line` sees lines `0.19` and `0.18` and fails that release pull
   request. It cannot merge.
4. **Nothing can be released now, on any platform.** A Windows bug fix would
   go into the same release pull request, and that pull request is stuck
   behind your unfinished feature.

One half-landed feature freezes releases for everyone until somebody writes the
other half. That is the cost of merging early, and it is paid by whoever needs
to ship a hotfix that week, not by you.

### So: pair before you merge

Put both implementations on one branch and open one pull request.

```bash
git checkout main
git pull
git checkout -b feat/split-panes      # not feat/split-panes-macos
```

Write the macOS half. Write the Windows half. Update
[docs/parity.md](docs/parity.md) in the same branch. Open one pull request
containing all of it. Both platform CI jobs run, `version-line` stays green
because no version file moved, and when release-please picks it up afterwards
it bumps every platform together.

If the two halves are large enough that one diff is unreviewable, keep the
shared branch and stack pull requests **into it** rather than into `main`:

```
main
 └── feat/split-panes            <- the integration branch, merges to main last
      ├── feat/split-panes-macos     <- PR targets feat/split-panes
      └── feat/split-panes-windows   <- PR targets feat/split-panes
```

`main` never sees a half-finished feature, so releases never freeze.

### Only starting one half?

Say so in the pull request, and target a feature branch rather than `main`. If
you have written the macOS half and cannot write the Windows one, open it
against a `feat/<slug>` branch and say in the description that Windows is
outstanding. Somebody else can push the other half onto the same branch. That
is a normal and welcome way to contribute; what does not work is merging half
of it to `main` and hoping.

### The exception

Some things are genuinely one platform's alone and always will be: Windows
first-run onboarding, anything about Rosetta or Gatekeeper, an installer
detail. These do not have a counterpart to pair with.

Commit them as `fix:` or `chore:` rather than `feat:` where that is honest,
which moves the patch instead of the line and keeps the platforms level. If it
truly is a feature and truly cannot exist elsewhere, say so in the pull request
and add the row to [docs/parity.md](docs/parity.md) explaining why. It will
need a decision about the version line before it can be released, and that is a
conversation worth having in the open rather than a rule to route around.

---

## Opening a pull request

### 1. Fork and branch

If you do not have write access to the repository, fork it on GitHub first, then
clone your fork. If you do have write access, branch directly.

Never commit to `main`. Branch first:

```bash
git checkout main
git pull
git checkout -b fix/cursor-visible-after-resize
```

Name the branch after the type of change, matching the commit prefix:
`feat/<slug>`, `fix/<slug>`, `docs/<slug>`, `chore/<slug>`.

Name a feature after the feature, not after a platform: `feat/split-panes`,
never `feat/split-panes-macos`. One branch carries every platform's half of it.
See [Features land on every platform at once](#features-land-on-every-platform-at-once).

### 2. Make the change and test it locally

Run the same commands CI will run, for the platform you touched. On Windows:

```powershell
cd windows
dotnet run --project tests/Zharp.Core.SmokeTests -c Release
dotnet build src/Zharp.App/Zharp.App.csproj -c Release
```

On macOS:

```bash
cd macos
./Scripts/check-shell-templates.sh
swift run -c release ZharpCoreSmokeTests
make app
```

Both must succeed before you push. A red build does not get reviewed.

### 3. Commit, signed off, with a conventional message

```bash
git add -A
git commit -s -m "fix: keep the cursor visible when the pane is scrolled to the bottom"
```

### 4. Push and open the PR

```bash
git push -u origin fix/cursor-visible-after-resize
```

Then either use the link Git prints, or the GitHub CLI:

```bash
gh pr create --fill
```

`--fill` uses your commit message as the title and body. To write them yourself:

```bash
gh pr create \
  --title "fix: keep the cursor visible when the pane is scrolled to the bottom" \
  --body "The scroll offset was recomputed after the cursor row was clamped, so a resize during output parked the cursor one row below the viewport. Tested on Windows 11 and macOS 15."
```

Give the pull request a title that is itself a valid Conventional Commit
message. If the PR is squash merged, that title becomes the single commit
message on `main`, and it is what the release tooling reads to decide the next
version. A PR titled "cursor fix" produces no release at all.

Open it as a draft if it is not ready:

```bash
gh pr create --draft --fill
```

### What to expect in review

* Someone will read it. Zharp is small, so it is usually within a few days. If a
  week goes by with nothing, comment on the PR. That is not rude, it is a
  reasonable nudge.
* Reviewers look for: does it work, is there a test for it, does it match the
  style of the surrounding code, and does it stay in scope. That last one comes
  up most often. A PR that fixes one bug and also reformats a file and also
  renames three things is hard to review, and will be asked to split.
* If your change affects both apps in principle, but you only implemented it on
  one, say so in the PR description. That is a completely acceptable
  contribution. It just needs to be visible, so a follow-up issue can be opened
  for the other platform.
* Changes to the terminal engine (`Zharp.Core` on Windows, `ZharpCore` on macOS)
  get the closest reading, because those two are meant to stay behaviourally
  identical. A change to one usually implies a change to the other.
* Expect to be asked for a test. If you fixed a parsing or rendering bug, there
  is almost certainly a place in the smoke suite where a check for it belongs.
* Address review comments by pushing more commits to the same branch. Do not
  close the PR and open a new one, the discussion is worth keeping.
* Once it is approved and green, a maintainer merges it. You do not need to do
  anything else. The release, changelog and version bump are automated, and
  happen later, in a batch.

---

## Things you should never edit by hand

**Version numbers.** Release automation owns every file that carries one:

* `.release-please-manifest.json` at the repository root
* `windows/version.txt`, `windows/Directory.Build.props`,
  `windows/installer/zharp.iss`
* `macos/version.txt`, `macos/Sources/ZharpApp/App.swift`

If you bump one of these in a pull request it will be reverted, it will
conflict with the open release pull request, `release.yml` refuses to build a
release whose `version.txt` disagrees with the tag, and `version-line.yml`
refuses to merge a pull request that puts the platforms on different lines.

**The changelogs.** `windows/CHANGELOG.md` and `macos/CHANGELOG.md` are
generated from commit messages, one per platform, because each platform now
has its own version history. `CHANGELOG.md` at the root is frozen: it records
the move into this repository and stops at 0.16.0. Write a good commit message
instead of editing any of them.

**Generated and build output.** None of this belongs in a commit:

* `windows/src/**/bin/`, `windows/src/**/obj/`, `windows/installer/Output/`
* `macos/.build/`, `macos/dist/`, `macos/Packaging/AppIcon.icns`

All of it is gitignored already. If `git status` shows any of it, something is
wrong with your tree, not with the ignore rules.

**`macos/Packaging/Info.plist` version fields.** They contain the literal
placeholder `__VERSION__`, which the packaging script substitutes at build time.
Replacing it with a real number breaks the build in a confusing way.

---

## Licence

Zharp is MIT licensed. See `LICENSE`. By contributing, and by signing off your
commits under the DCO, you agree that your contribution is licensed under the
same terms.

The repository bundles third party assets that carry their own licences and
attribution requirements: Tabler Icons (MIT), used in both apps, and DM Mono
(SIL Open Font License 1.1), used in the macOS app. If you add another third
party asset, its licence and attribution have to be recorded alongside these
before it can be merged.
