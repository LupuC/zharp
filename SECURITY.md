# Security policy

Zharp is a terminal emulator. That means two things are true at the same time:

1. Running arbitrary commands is the whole point of the program, so "Zharp let
   me run `rm -rf`" is not a vulnerability.
2. Zharp parses a stream of bytes that it did not write and cannot trust. Any
   program you run, any file you `cat`, any SSH session, any log tail can push
   escape sequences into the terminal. If one of those sequences can make Zharp
   run something, write a file, leak data or corrupt memory without you asking,
   that is a real vulnerability and we want to hear about it.

This policy is about the second kind.

Zharp is maintained by one person in their spare time. The timelines below are
what can honestly be met, not what sounds good.

## Supported versions

| Version | Supported |
|---|---|
| 0.15.x and later | Yes, fixes land in a new patch release |
| 0.14.x and earlier | No, please upgrade |

Anything before 0.15.0 was released separately per platform, before the two
apps moved into this repository. Those builds are not maintained. If you are on
one of them, update to the current release first and check whether the issue is
still there.

To find your version:

- macOS: menu bar, **Zharp > About Zharp**
- Windows: **Settings > About**

Only the latest release gets fixes. There are no long term support branches and
no backports.

## Reporting a vulnerability

**Do not open a public GitHub issue, a discussion, or a pull request for a
security problem.** Those are visible to everyone the moment you press the
button, including before there is a fix.

Report it privately through GitHub private security advisories:

1. Open <https://github.com/LupuC/zharp/security/advisories/new> in a browser
   while signed in to GitHub. If that URL gives you a 404, go to the repository
   at <https://github.com/LupuC/zharp>, click the **Security** tab, then
   **Report a vulnerability**.
2. Fill in the title and description. The form is private, only you and the
   maintainer can read it.
3. Press **Submit report**.

You need a GitHub account to use the form. It is free, and it is the only
reporting channel: there is no security email address for this project, on
purpose, so that reports do not sit in a personal inbox.

### What to put in the report

The more of this you include, the faster it gets fixed:

- Zharp version and platform (for example `0.15.0`, macOS 15.2 on Apple
  silicon, or Windows 11 24H2).
- The shell and its version, if the shell is involved (`zsh --version`,
  `bash --version`, `pwsh --version`).
- What an attacker gains. "Escape sequence X writes to an arbitrary path" is a
  finding. "Escape sequence X is handled slightly differently from the spec" on
  its own is a bug report, not a security report.
- A reproduction that someone else can run. For escape sequence issues, the
  most useful form is a command that prints the bytes, for example:

  ```bash
  printf '\033]133;C\007'
  ```

  or a small file plus the command that displays it:

  ```bash
  curl -sO https://example.invalid/poc.bin
  cat poc.bin
  ```

  Raw bytes as a hex dump are fine too, and are safer to paste into a form:

  ```bash
  xxd poc.bin
  ```

- What you expected to happen, and what actually happened.
- Whether you want to be credited in the advisory and the release notes, and
  under what name or handle.

Please do not include real secrets, tokens or customer data in the report. If a
reproduction needs a credential, use a throwaway one.

### What happens next, and when

| Stage | Target |
|---|---|
| First human reply acknowledging the report | Within 5 working days |
| Assessment: confirmed or not, and a severity | Within 15 working days of the first reply |
| Fix released for a confirmed high severity issue | Within 45 days of confirmation, sooner if a workaround is not possible |
| Fix released for a confirmed low or medium severity issue | Rolled into the next regular release |
| Public advisory published | After the fix ships, or 90 days after the report, whichever comes first |

If a stage is going to slip, you get a message saying so and why, rather than
silence. If you have not heard anything after 10 working days, it is fine and
welcome to post a plain "any update?" comment on the advisory thread.

Once a fix is released, a GitHub security advisory is published with a
description, the affected versions, the fixed version and, unless you asked
otherwise, credit to you. A CVE will be requested through GitHub for anything
that is not trivially low severity.

There is no bug bounty. This is a free project with no revenue behind it, so
the only reward on offer is credit in the advisory and a genuine thank you.

## In scope

Reports about these are wanted:

- **Escape sequence parsing.** Anything reachable by writing bytes to the
  terminal: CSI, DCS, OSC and APC handlers, character set switching, sixel or
  image handling, malformed or truncated sequences, sequences with absurd
  parameter counts or lengths. Crashes, hangs that need a force quit, memory
  corruption, and out of bounds reads or writes all count.
- **Anything that turns terminal output into execution.** An escape sequence
  that causes a command to run, that puts text on the input line where a stray
  newline would submit it, or that defeats bracketed paste.
- **Shell integration, OSC 133 and OSC 7.** Zharp uses OSC 133 to work out
  where commands start and end, and OSC 7 to track the working directory. A
  crafted OSC 7 payload that escapes the directory tracking, writes outside it,
  or gets interpreted as something other than a path is in scope. So is anything
  in the shell integration scripts Zharp installs into your shell profile,
  including unquoted expansion of hostile directory names.
- **Command blocks and the command history panel.** Captured command text and
  output is stored and re-displayed. Anything that makes stored output execute,
  escape its block, or read files it should not is in scope.
- **The agent status indicator.** It reads signals coming from processes
  running in the terminal. Anything that lets a hostile process drive it into
  unsafe behaviour is in scope.
- **OSC 8 hyperlinks and clipboard sequences.** Links that render as one target
  and open another, links with schemes that should never be opened without
  confirmation, and sequences that read from or silently write to the system
  clipboard.
- **File handling.** Config files, theme files, session restore data and log
  files: path traversal, symlink attacks, unsafe permissions on files Zharp
  creates, code execution through a crafted theme or config.
- **Local privilege issues.** Zharp reading or writing something outside its
  own data directory that it has no business touching, or leaving a file world
  writable.
- **The update mechanism.** Anything that would let someone else's payload be
  presented as a Zharp update.
- **Tab drag and tear out.** The inter-window and inter-process handoff that
  moves a live session into another window, if it can be hijacked by another
  local process.
- **Secrets ending up somewhere they should not.** For example a password typed
  at a prompt landing in the history panel, in a crash report, or in a log file
  on disk.

## Out of scope

These are not security vulnerabilities in Zharp. They may still be worth a
normal GitHub issue, they just will not be treated as security reports:

- Zharp running commands you typed, pasted or approved. That is the product.
- Damage caused by a command you chose to run, including a destructive command
  suggested to you by an AI tool.
- A shell, a program you ran inside Zharp, or an SSH server having its own
  vulnerability. Report those to their own maintainers.
- Bugs in the operating system, in AppKit, in WinUI or in the Windows App SDK.
  Report those to Apple or Microsoft. If Zharp misuses one of those APIs in a
  way that creates a problem, that part is in scope and is worth reporting.
- Resource exhaustion from output you asked for, for example printing a
  gigabyte of text or opening hundreds of tabs until the machine slows down.
- Someone with physical access to an unlocked machine, or with an existing
  interactive session as your user, reading your files. At that point they
  already have everything Zharp has.
- Missing compiler or linker hardening flags, missing sandbox entitlements and
  similar hygiene findings, unless you can show an actual exploit that they
  would have stopped.
- Automated scanner output with no proof of concept and no explanation of
  impact. Reports that are clearly a dumped tool report will be closed.
- Missing security headers, DNS or TLS configuration findings on the project
  website or on GitHub itself. GitHub's own infrastructure belongs to GitHub's
  bug bounty programme, not to this one.
- Social engineering, phishing of the maintainer, or anything requiring the user
  to install a modified build of Zharp.

## Coordinated disclosure

Please give the project a chance to ship a fix before going public. The
target is a fix within 90 days of your report, and the advisory is published
once the fix is out.

If 90 days pass and there is no fix and no plan, you are free to publish. Tell
the maintainer first, and the advisory will be published from this side too so
that users at least learn there is something to avoid. Publishing a working
exploit for an unfixed issue before that window is up is not something this
project will thank you for, though nobody is going to send lawyers after you
either.

Good faith security research on your own machine, against your own copy of
Zharp, is welcome. No legal action will be taken over it.
