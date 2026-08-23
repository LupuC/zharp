# Publishing Zharp to winget

Zharp is distributed through the Windows Package Manager community repository,
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs). It is free:
there is no fee, no developer account and no signing requirement.

A manifest pins an installer URL **together with the checksum of the file
behind it**, so it must point at a URL that never changes what it serves. That
is what `https://zharp.app/download/windows/<version>` is for - the plain
`/download/windows` always follows the newest build and would break every
published manifest on the next release.

## Package identity

| | |
|---|---|
| Package identifier | `Zharp.Zharp` |
| Installer type | `inno` (silent switches are built in) |
| Scope | `user` - `PrivilegesRequired=lowest`, so no admin prompt |
| Product code | `{C7A9D1E4-4B2F-4A63-9C0D-2E8F5B7A1D36}_is1` |

The product code is the installer's `AppId` with Inno Setup's `_is1` suffix. It
is how winget recognises an install it did not perform, and how it detects that
an upgrade landed. It must never change - the same reason the `AppId` never
changes.

## First submission (one time)

Run from a machine with the tooling installed
(`winget install Microsoft.WingetCreate`):

```powershell
wingetcreate new https://zharp.app/download/windows/<version> --out .\manifests
winget validate .\manifests          # schema check before anyone sees it
winget install --manifest .\manifests  # installs it for real, as winget would
wingetcreate submit .\manifests --token <github-pat>
```

The PAT needs `public_repo` so the tool can fork winget-pkgs and open the pull
request. A bot then installs the package in a sandbox to validate it; a new
package usually also gets a human reviewer.

## Every release after that

`.github/workflows/release.yml` opens the version-bump pull request on its own,
once `WINGET_TOKEN` (the same kind of PAT) exists as a repository secret.
Without the secret the step logs a line and skips, so releases never fail over
winget.

## Worth knowing

Zharp updates itself. Someone who installs through winget will be upgraded in
place by the in-app updater, after which `winget list` reports the older
version until winget's own upgrade runs. Harmless, but the tidy fix is to skip
the in-app updater when the install came from winget.
