# Changelog

One version line covers every platform. The entry below describes the release
that put both apps in this repository, and it carries the artifacts for both:
the Windows installer and the macOS disk image.

**This file is frozen at 0.16.0.** From 0.16.0 onward each platform keeps its
own changelog, because each platform keeps its own version: see
[windows/CHANGELOG.md](windows/CHANGELOG.md) and
[macos/CHANGELOG.md](macos/CHANGELOG.md).

Every platform is on the same *line*, the `0.16` in `0.16.2`. The third number
belongs to one platform's own bug fixes, so Windows can be on 0.16.2 while
macOS is still on 0.16.0, which means macOS had nothing to fix and was never
rebuilt. `.github/workflows/version-line.yml` fails any pull request that lets
the lines drift apart.

## [0.16.0](https://github.com/LupuC/zharp/commit/3fc1492c489a0bd1019cb486d1bacd06589d153f) (2026-08-23)

The first release built from the combined repository, and the first release of
Zharp as open source. No behaviour of either app changed here. What changed is
where the code lives, how it is versioned, and the terms it is published under.

### Features

* consolidate Zharp into one open source monorepo ([3fc1492](https://github.com/LupuC/zharp/commit/3fc1492c489a0bd1019cb486d1bacd06589d153f))

### Repository layout

* The Windows app and the macOS app now live in one repository instead of two,
  under `windows/` and `macos/`. `shared/` holds the platform neutral assets,
  `docs/` the documentation, and `linux/` is an empty placeholder: no code, no
  toolkit chosen yet.
* Both apps keep their own build systems. `windows/` is the C# WinUI 3 project
  built with the .NET SDK, `macos/` is the Swift AppKit project built with
  SwiftPM. Nothing was rewritten to move.

### Versioning and releases

* Windows and macOS share one version number starting at 0.16.0. Windows was
  last released as 0.14.0 and macOS as 0.14.1, so the two were already a patch
  apart; unifying at 0.16.0 clears that and keeps the numbers honest going
  forward.
* One git tag (`v0.16.0`) and one GitHub release per version. Both the Windows
  installer and the macOS disk image, with their SHA-256 sidecars, attach to
  that same release. Downloading "the 0.16.0 build" no longer means picking a
  platform first and hoping the numbers line up.
* Version bumps are automated. release-please rewrites every file that holds a
  version number, on all platforms at once, and refuses to let one platform
  release without the other.

### Licence and contributions

* Zharp is open source under the MIT licence.
* Contributions are accepted under the Developer Certificate of Origin. Sign
  off your commits with `git commit -s`. There is no CLA and nothing to sign
  separately.

## Before 0.16.0

Everything before 0.16.0 happened in two separate private repositories, one per
platform, each with its own changelog and its own version numbers. Windows
reached 0.14.0 there and macOS reached 0.14.1.

Neither the old changelogs nor the old commit histories were carried across:
this repository starts from a single commit that imports both trees, so
`git log` here begins at the consolidation and not at the first line either app
ever had. The releases made from the old repositories are not reachable from
here either. If you are looking for how a specific file got the way it is, the
answer for anything older than 0.16.0 is not in this history.
