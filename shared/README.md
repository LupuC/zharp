# shared/

Platform neutral assets that more than one Zharp app needs to agree on, kept
here once so there is a single place to look when they disagree.

Nothing in this directory is compiled, imported, or read at runtime. The apps
carry their own copies of this content, and `scripts/check-shared-drift.sh`
fails the build when a copy stops matching the file here.

## What is in here

```
shared/
  shell-integration/     the prompt hook scripts, one file per shell
    zharp.zsh
    zharp.bash
    zharp.fish
    zharp.ps1
  themes/
    palettes.json        the terminal color schemes, as data
  README.md              this file
```

## The rule

`shared/` is for **data**. Scripts, color values, brand assets, test fixtures.
Things that are true about Zharp regardless of which language the app in front
of you is written in.

`shared/` is **not** a shared abstraction layer, and it must never grow into
one. No cross platform core library, no common interface the platforms
implement, no build-time code generation that the apps depend on to compile.

That is not a stylistic preference. The whole point of this project is that
each platform gets a genuinely native implementation: real AppKit on macOS,
real WinUI 3 on Windows, and whatever turns out to be right on Linux. A shared
abstraction layer is how that stops being true. It starts as one small helper,
then the native code has to bend around it, and eventually every platform is
running the same lowest common denominator wearing a native costume. Duplicated
native code that is checked for drift is a better trade than shared code that
quietly flattens all three apps.

So the test for a new file here is: **could a person read this file and hand
implement it correctly in a language that does not exist yet?** If yes, it
belongs. If it only makes sense as something an app links against, it does not.

### Belongs here

- Shell integration scripts (real `.zsh`, `.bash`, `.fish`, `.ps1` files)
- Color palettes and theme values, as JSON
- Icons, logos, and other brand artwork
- Terminal escape sequence test fixtures: an input byte stream plus the screen
  state every emulator should produce from it
- Keybinding tables, default settings values, and similar plain data
- Documented constants such as the OSC sequence numbers Zharp emits and parses

### Does not belong here

- Source code in any language, including a "tiny" utility both apps could use
- A cross platform core, engine, protocol layer, or plugin API
- Anything either app links, imports, `#include`s, or loads at runtime
- Generated code, or a generator the app builds depend on
- Anything platform specific: `.xaml`, `.xib`, entitlements, installer scripts,
  signing configuration, per platform CI

## Why the copies exist at all

The scripts and palettes are duplicated on purpose. The apps embed them as
string literals and constant tables rather than reading `shared/` at runtime,
because a terminal that cannot find its own resource directory should still
start a working shell.

Duplication that nothing checks is how Zharp 0.14.0 shipped a broken zsh
integration. A stray `fi` was left behind during an edit to the zsh script,
which lives inside a Swift string literal, so the Swift compiler saw a perfectly
valid string and said nothing. The generated `.zshrc` aborted on a parse error
and shell integration was silently dead on macOS for the entire release.

`scripts/check-shared-drift.sh` exists so that cannot happen twice. It syntax
checks every script here with that shell's own parser, then extracts the
embedded copy out of each app's source, undoes the language specific string
escaping, and compares. Any difference fails, with a diff.

## Where each copy lives

| Canonical file | Embedded copy |
| --- | --- |
| `shell-integration/zharp.zsh` | `macos/Sources/ZharpApp/ShellDiscovery.swift`, the `let script` literal in `zsh()` |
| `shell-integration/zharp.bash` | `macos/Sources/ZharpApp/ShellDiscovery.swift`, the `let script` literal in `bash()` |
| `shell-integration/zharp.fish` | `macos/Sources/ZharpApp/ShellDiscovery.swift`, the `let hook` literal in `fish()` |
| `shell-integration/zharp.ps1` | `macos/Sources/ZharpApp/ShellDiscovery.swift`, the `let integration` literal in `pwsh()`, and `windows/src/Zharp.App/ShellDiscovery.cs`, the `PowerShellIntegration` constant |
| `themes/palettes.json` | `macos/Sources/ZharpCore/Terminal/Palette.swift` and `windows/src/Zharp.Core/Terminal/Palette.cs` |

Two things are deliberately **not** covered yet:

- The cmd.exe `PROMPT` string in `windows/src/Zharp.App/ShellDiscovery.cs` has
  no counterpart on any other platform, so there is nothing to keep in sync.
- Windows reports the working directory with `OSC 9;9` where macOS uses
  `OSC 7`. Both emulators already parse both, so this is history rather than a
  requirement. The drift check knows about that single substitution by name and
  checks the Windows copy through it, which means every other difference in
  that script still fails.

## Prerequisites for the drift check

| Tool | Needed for | Minimum | Check it with |
| --- | --- | --- | --- |
| `python3` | extraction and comparison | 3.8 | `python3 --version` |
| `zsh` | `zsh -n` on `zharp.zsh` | 5.8 | `zsh --version` |
| `bash` | `bash -n` on `zharp.bash` | 3.2 | `bash --version` |
| `fish` | `fish --no-execute` on `zharp.fish` | optional | `fish --version` |
| `pwsh` | parser check on `zharp.ps1` | optional | `pwsh --version` |

macOS and the GitHub runner images ship `python3`, `zsh` and `bash` already.
`fish` and `pwsh` are optional: when they are not installed the check prints
`SKIPPED` for those two files and still passes.

## Changing a shared file

Every step below is required. Skipping step 2 means your change does not ship.

**1. Edit the file here.**

The shell scripts have a header of comment lines, then this sentinel line:

```
# zharp-canonical-body-begins-below
```

Everything above the sentinel is documentation and is ignored by the drift
check. Everything below it is compared byte for byte against the app copies.
Edit below the sentinel, and leave the sentinel line exactly as it is.

`zharp.fish` and `zharp.ps1` are a single long line each, on purpose. Those two
are passed to the shell as one command line argument (`fish -C` and
`pwsh -Command`), so they cannot contain a newline. Keep them one line.
`zharp.ps1` must also contain no double quote characters, because the Windows
call site wraps the whole thing in double quotes.

**2. Make the same edit to every embedded copy** listed in the table above, and
re-apply that language's escaping as you go.

Inside a Swift `"""` literal and inside a C# `"` string, a backslash is written
twice and a double quote is written `\"`:

| In `shared/` | In Swift or C# source |
| --- | --- |
| `\033` | `\\033` |
| `\007` | `\\007` |
| `\033\\` | `\\033\\\\` |
| `\[` and `\]` | `\\[` and `\\]` |
| `"` | `\"` |

Swift also treats `\(` as string interpolation. None of the current scripts
contain it, and the drift check refuses to run rather than guess if one appears,
so if you need a literal `\(` you have to teach the unescaper about it first.

`zharp.ps1` needs no escaping at all in either language: it builds ESC and BEL
in PowerShell with `([char]27)` and `([char]7)`, and uses only single quotes.

For `themes/palettes.json`, the hex values here are written as `RRGGBB` with no
prefix, and appear in the app source as `0xRRGGBB`. Case does not matter, the
check compares them uppercased.

**3. Run the check from the repository root.**

```bash
cd /path/to/zharp
./scripts/check-shared-drift.sh
```

**4. Confirm it passed.** Successful output looks like this, and the exit
status is 0:

```
==> syntax  zharp.zsh    OK (zsh -n)
==> syntax  zharp.bash   OK (bash -n)
==> syntax  zharp.fish   SKIPPED (fish is not installed on this machine)
==> syntax  zharp.ps1    SKIPPED (pwsh is not installed on this machine)
==> drift   zharp.zsh    OK (macos/Sources/ZharpApp/ShellDiscovery.swift)
==> drift   zharp.bash   OK (macos/Sources/ZharpApp/ShellDiscovery.swift)
==> drift   zharp.fish   OK (macos/Sources/ZharpApp/ShellDiscovery.swift)
==> drift   zharp.ps1    OK (macos/Sources/ZharpApp/ShellDiscovery.swift)
==> drift   zharp.ps1    OK (windows/src/Zharp.App/ShellDiscovery.cs, through the known ]7;file:// -> ]9;9; variant)
==> themes  palettes.json OK (9 themes, macos/Sources/ZharpCore/Terminal/Palette.swift)
==> themes  palettes.json OK (9 themes, windows/src/Zharp.Core/Terminal/Palette.cs)
==> shared/ is in sync with both apps
```

The two `SKIPPED` lines become `OK` on a machine that has `fish` and `pwsh`
installed. Every other line must say `OK`.

Check the exit status explicitly if you are unsure:

```bash
./scripts/check-shared-drift.sh; echo "exit status: $?"
```

`exit status: 0` means everything agrees. `exit status: 1` means something
drifted, and the failing check printed a diff above the summary. In that diff,
`-` lines are what `shared/` says and `+` lines are what the app source says.

## Adding a new shell or a new theme

Adding either one means adding a check, otherwise the new file is unprotected
duplication and this directory has bought you nothing.

For a new shell script:

1. Add `shared/shell-integration/zharp.<shell>` with a header, the sentinel
   line, and the body.
2. Add a `check_syntax` line to `scripts/check-shared-drift.sh` naming that
   shell's own syntax checker, and its skip behaviour if the binary is not
   installed.
3. Add a row to the `CHECKS` table in the same script, pointing at the app
   source file and the name of the literal the copy lives in.
4. Add a row to the "Where each copy lives" table above.

For a new theme, add an object to the `themes` array in
`themes/palettes.json` and add the matching palette to both
`macos/Sources/ZharpCore/Terminal/Palette.swift` and
`windows/src/Zharp.Core/Terminal/Palette.cs`. The theme ids and their order
must match across all three files, since the check compares them in order.
