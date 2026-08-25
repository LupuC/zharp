# Sessions on another machine

A terminal tab stops describing this computer the moment you type `ssh`. The
prompt is still there, the tab is still the same tab, but the directory it
reports belongs to a machine the shell is no longer on.

That used to be invisible. The changes panel would keep showing the repository
you left behind, with a branch name and a file list and line counts, all read
from local disk while you worked somewhere else entirely. Nothing looked wrong,
which is what made it worth fixing: a panel that says "not a git repository" is
useless for a second, and a panel that shows the wrong repository is misleading
for as long as you believe it.

This describes how Zharp works out where a session is, and what it does once it
knows.

## Working out the machine

Three signals, in order of how much they can be trusted.

**The `ssh` command you typed.** Zharp already reads the prompt line to record
history, so it sees `ssh srv1` at the moment you press Enter, before anything
has been sent. This is the only signal that needs no cooperation at all from
the far end, which matters because the other two are optional and the plainest
servers volunteer neither. It also carries the flags: a `-p`, a `-i`, a `-J`
are what make the difference between reaching the same machine and reaching a
different one, or nothing.

The session is local again when the local shell draws a fresh prompt (OSC 133).
A remote shell need not say goodbye, and you may have ended the connection by
closing a laptop, so the return of the prompt is the signal rather than
anything the far end sends.

**OSC 7.** `file://host/path` carries both halves. Zharp used to parse this and
throw the host away, keeping a POSIX path it then treated as a Windows one.
Now a host that is not this machine marks the session remote and the path is
kept in the far end's own notation. fish emits this by default, and so does any
Linux shell sourcing the vte profile script.

**The window title.** Debian and Ubuntu ship a `.bashrc` that puts
`user@host: ~/dir` in the title of any xterm-like terminal, and zsh's default
does the same. It covers a great many servers where nobody configured anything.
It is a fallback and never a promotion: a title is a string any program can set
to anything, so it is only read once the session is already known to be
elsewhere, and only a value that looks like a path is believed.

If none of the three yields a directory, the panel says so. "Somewhere on
srv1" is a true statement; the local repository is not.

## Reading git over there

`git` runs on the machine the repository is on. Zharp opens a second ssh
connection to the host you are already connected to, and runs the same
read-only commands it would run locally.

It is one connection per host, not one per question. The panel asks several
things every few seconds, and an ssh handshake costs a few hundred
milliseconds, so a connection per question would make the panel slower than
running `git status` by hand. The connection is a long-lived `ssh host sh` with
commands written to its stdin, framed by a marker line; OpenSSH's own answer to
this is `ControlMaster`, which the Windows build does not implement. It closes
after five idle minutes, and when Zharp quits.

Output comes back base64 encoded. That is not paranoia about the network, it is
about the framing: git's `-z` output has NUL bytes and newlines inside single
records, and a filename is allowed to contain both, so a line-oriented protocol
reading raw output would eventually mistake a filename for the end of an
answer. Every argument sent is single-quoted for the same reason.

The polling is slower than it is locally, six seconds against two, and the
per-file line counts come from one `git diff --numstat` for the whole tree
rather than one `git diff` per file. Locally that per-file loop costs a
process each and nobody notices; across a network it would be a round trip per
row, repeated forever, for small grey numbers.

## What it will not do

**It never prompts.** `BatchMode=yes` is forced ahead of anything in your ssh
config, so a host that wants a password or a hardware token fails immediately
and the panel says why. A GUI process has nowhere to draw a password prompt and
nothing to read it from, so a connection that could ask would be a connection
that could hang with no explanation.

**It never writes.** No stage, no commit, no checkout, no fetch. The same rule
as the local panel, for the same reason: the terminal is one pane away and is
better at all of it.

**It never dials a machine it only heard about.** A host learned from OSC 7 or
a window title is a name that arrived over the wire from a program on another
computer. Zharp will use it to say where you are, and will not use it to decide
where to connect next. Only a host you reached yourself, with a command Zharp
watched you type, is one it will reach on its own.

**It can be turned off.** Settings has a switch. Off means the panel says where
you are and stops there. That is the right setting on a host where every login
is audited, or where a second session would trip an alert.

## When it cannot help

- A remote that is not POSIX (a Windows server over ssh) has no `sh` to run.
- A remote without `base64` cannot frame its answers safely, so it is refused
  rather than parsed optimistically.
- A host reached through something other than `ssh`: mosh, a container exec, a
  serial console. Zharp watches for `ssh` specifically.
- A host whose key is not in `known_hosts` yet. Connect once in the terminal
  and accept it; the panel then works.

In each case the panel names the machine and says what stopped it, which is the
whole point. The failure mode this replaced was silence plus a plausible answer
from the wrong computer.

## Testing it

`ZHARP_SSH` overrides which ssh binary is run. The smoke tests point it at a
stub that ignores the connection flags and starts a local POSIX shell, so the
handshake, the framing, the quoting and the encoding are all exercised for real
on a machine with no server to connect to. See the ssh transport section in
`windows/tests/Zharp.Core.SmokeTests/Program.cs`.
