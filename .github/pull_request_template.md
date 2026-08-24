## What changed

<!-- Describe the change itself, in plain terms. If it touches the UI, a before and after
screenshot or a short screen recording saves everyone a lot of guessing. -->

## Why

<!-- The problem this solves. Link the issue if there is one, using a closing keyword so the
issue closes automatically when this merges, for example:

Closes #123

If there is no issue, explain the motivation here instead. -->

## Platforms affected

<!-- Tick every platform whose code this PR touches. -->

- [ ] Windows (`windows/`)
- [ ] macOS (`macos/`)
- [ ] Linux (`linux/`)
- [ ] Shared assets (`shared/`)
- [ ] Docs, CI, or repo tooling only

<!-- A `feat:` has to land on EVERY platform in one pull request. Zharp ships one version line,
0.19 means the same thing everywhere, and version-line.yml enforces it as a required check.
Merging half a feature to main does not fail anything today; it fails the next release pull
request instead, and freezes releases for every platform until somebody writes the other half.

If you have only written one half, target a feature branch rather than main and say so here.
See "Features land on every platform at once" in CONTRIBUTING.md.

Genuinely platform-specific things (onboarding, Gatekeeper, an installer detail) are the
exception. Say why here. -->

## How it was tested

<!-- Be specific. "Works on my machine" tells a reviewer nothing. Include:
     - the OS and version you tested on
     - the shell you tested with (bash, zsh, fish, PowerShell, cmd), since shell integration
       behaves differently in each
     - the exact commands or steps you ran to confirm the change works
     - anything you could not test and why -->

Tested on:

Steps:

1.
2.
3.

## Checklist

- [ ] The PR title follows Conventional Commits, for example `feat(macos): tear tabs out into a new window`, `fix(windows): stop the block header flickering`, or `docs: explain shell integration setup`. The title becomes the squashed commit message and drives release notes, so it matters.
- [ ] Every commit is signed off for the DCO. Commit with `git commit -s`, which appends a `Signed-off-by:` line. To fix an existing branch: `git rebase --signoff main`, then `git push --force-with-lease`.
- [ ] If this is a `feat:`, every shipping platform is covered by this PR, or this PR targets a feature branch rather than `main`.
- [ ] `docs/parity.md` is updated if this adds, removes, or changes a user visible feature on any platform.
- [ ] Tests pass locally, on at least the platform I changed:
  - macOS, from `macos/`: `make test`
  - Windows, from `windows/`: `dotnet run --project tests/Zharp.Core.SmokeTests` (exit code 0 means every test passed)
- [ ] I have read `CONTRIBUTING.md` and this change is mine to contribute under the MIT licence.
