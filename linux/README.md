# Zharp for Linux

**There is no Linux code here yet.** This directory is a placeholder so the repo layout
matches the plan. A Linux port is planned, but nothing has been written and no toolkit
has been chosen.

If you came here looking for something to download, there is nothing to download. Zharp
currently ships for Windows (`windows/`, C# and WinUI 3) and macOS (`macos/`, Swift and
AppKit).

## What is still open

The one real decision is the UI toolkit. All three of these are realistic, and none of
them has been ruled out:

- **GTK4 with libadwaita.** The most native looking result on GNOME, good Wayland support,
  and the widest packaging story (Flatpak in particular). It would mean a third UI codebase
  in a third language, most likely Rust or Vala or C.
- **Qt.** Very mature, good text and font handling, works consistently across desktop
  environments rather than looking best on one. Also a third UI codebase, most likely C++.
- **Avalonia with .NET.** The interesting option, because the Windows app is already C#.
  A good part of the Windows UI layer could potentially be reused instead of rewritten,
  which is the only path here that reduces the total amount of code rather than adding to
  it. The tradeoff is that the result is less likely to feel native on any given desktop,
  and .NET packaging on Linux has its own rough edges.

Pick your poison. The right answer probably depends on who actually shows up to write it
and what they are fluent in.

## What already ports over

The part people assume is hard is mostly done. The terminal core in
`macos/Sources/ZharpCore/` splits into two pieces:

- `Terminal/` is the VT parser, emulator, screen buffer, palette, and UTF-8 decoder. It is
  plain Swift with no OS calls at all, so it is portable as is.
- `Pty/PseudoTerminal.swift` is the pseudoterminal host. It uses `openpty`, `posix_spawn`,
  and `ioctl` with `TIOCSWINSZ`, which are the same Unix APIs on Linux as on macOS. The
  file currently does `import Darwin` behind a `#if canImport(Darwin)` guard, so porting it
  means adding a `Glibc` branch next to that guard, not rewriting the logic.

Shell integration ports over too. The hooks in `macos/Sources/ZharpApp/ShellDiscovery.swift`
emit OSC 133 for prompt and command marks and OSC 7 for the working directory. Those escape
sequences are shell specific, not OS specific, so the zsh, bash, fish, and pwsh snippets work
unchanged on Linux. What needs adjusting is shell discovery: default shell paths and the
`$SHELL` fallback differ between distributions.

So the realistic split is roughly: the terminal engine and pty handling come across from
macOS with small changes, and the entire UI layer (rendering, tabs, tab tear out, command
blocks, the history panel, themes, the agent status indicator) has to be built against
whichever toolkit gets picked.

## Want to help decide, or start it?

This is exactly the kind of thing that should be argued about before anyone writes code.
Open a discussion at https://github.com/LupuC/zharp/discussions and make your case,
especially if you have shipped a Linux desktop app before and know where the pain actually
is: HiDPI and fractional scaling, font rendering, IME, Wayland versus X11, or packaging.

If you would rather prototype than argue, a scrappy proof of concept that gets
`ZharpCore` compiling on Linux and paints a character grid in your toolkit of choice is
worth more than any amount of discussion. Open a draft PR and say what you found.

No timeline is promised here. This gets built when someone builds it.
