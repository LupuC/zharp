# Contributing to Zharp for macOS

## Building

Swift 5.9+ is all you need - the Xcode Command Line Tools are enough, a full
Xcode install is not required.

```bash
make build     # debug build
make test      # emulator + pty smoke tests (exit code = failures)
make app       # dist/Zharp.app
make dmg       # dist/Zharp-<version>.dmg
```

Run the app straight from the build with `make run`, or launch the packaged
bundle with `open dist/Zharp.app`.

## Layout

`ZharpCore` is the terminal engine and has no UI dependencies - it is a direct
port of the Windows build's `Zharp.Core`, and changes there should stay in step
with it. `ZharpApp` is the AppKit shell. See the Architecture section of the
README.

## Tests

`Tests/ZharpCoreSmokeTests` mirrors the Windows `Zharp.Core.SmokeTests` check
for check, plus pty integration tests that run a real `/bin/sh`. It is a plain
executable rather than an XCTest bundle so it runs without Xcode. Add a check
next to the ones it already makes:

```swift
check(rowText(e, 0) == "hello", "print basic text")
```

The process exits with the number of failures, so CI fails on any regression.

## Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
- `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `chore:`. release-please reads
them to decide the next version and to write CHANGELOG.md, so the prefix
matters:

* `feat:` bumps the minor version (while pre-1.0)
* `fix:`, `perf:`, `refactor:` bump the patch version
* `docs:` and `chore:` do not trigger a release

## Releasing

Releases are automated; nothing is built or uploaded by hand.

1. Merge conventional commits to `main`.
2. **Release Please** keeps a release PR open with the next version, an updated
   CHANGELOG.md, `version.txt` and the version literal in `Sources/ZharpApp/App.swift`.
3. Merging that PR tags `vX.Y.Z` and publishes a GitHub release.
4. **Release Disk Image** then runs the tests, builds the app, packages
   `Zharp-<version>.dmg`, and attaches it to the release along with its SHA-256
   and a stable `Zharp.dmg`.

The website serves that asset from `/download?platform=macos` and advertises the
version at `/api/version?platform=macos`, which is what the in-app update check
reads.

### Signing

The release workflow signs and notarizes when these repository secrets are set,
and falls back to an ad-hoc signature when they are not:

| Secret | Purpose |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application certificate, base64-encoded `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `MACOS_SIGN_IDENTITY` | Identity name, e.g. `Developer ID Application: Name (TEAMID)` |
| `MACOS_NOTARY_APPLE_ID` | Apple ID used for notarization |
| `MACOS_NOTARY_PASSWORD` | App-specific password for that Apple ID |
| `MACOS_NOTARY_TEAM_ID` | Apple Developer team id |

Without them the disk image still installs, but Gatekeeper warns that the
developer is unidentified and the user has to right-click → Open the first time.

`RELEASE_PLEASE_TOKEN` (a PAT with `contents: write` and `pull-requests: write`)
is optional but recommended: releases published with the default bot token do
not trigger the disk-image workflow, and the assets then need a manual
`workflow_dispatch` run.
