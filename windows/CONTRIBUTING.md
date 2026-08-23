# Contributing to Zharp

Zharp is in beta (0.x). Version 1.0 is the official launch.

## Workflow rules

1. **Branch per feature.** Nothing lands on `main` directly. Branch names:
   `feat/<slug>`, `fix/<slug>`, `chore/<slug>` - then open a PR.
2. **Conventional Commits.** Every commit message follows
   [Conventional Commits](https://www.conventionalcommits.org):
   `feat: ...`, `fix: ...`, `chore: ...`, `docs: ...`, `refactor: ...`,
   `perf: ...`. The changelog and version bumps are generated from these,
   so the type you pick matters: `feat` bumps the minor version, `fix`
   bumps the patch.
3. **Test before you push.** Locally:

   ```powershell
   dotnet run --project tests/Zharp.Core.SmokeTests   # exit code = failures
   dotnet build src/Zharp.App/Zharp.App.csproj -c Release
   ```

   CI runs the same on every push and PR; a red build does not merge.

## Releases (fully automated)

- [release-please](https://github.com/googleapis/release-please) watches
  `main` and maintains a release PR that accumulates the changelog from
  conventional commits.
- Merging that release PR: tags `vX.Y.Z`, updates `CHANGELOG.md`,
  `version.txt`, `Directory.Build.props` and `installer/zharp.iss`, and
  publishes a GitHub release.
- The release triggers the installer workflow: tests, self-contained publish,
  Inno Setup compile, and the setup exe (plus its SHA-256 file) is attached to
  the release - both as `ZharpSetup-X.Y.Z.exe` and as the stable
  `ZharpSetup.exe`. The repo is private, so the website does not link GitHub
  directly: zharp.website's `/download` route streams the newest release asset
  using a server-side token, and picks up each release automatically.
- **Never bump versions by hand.** The only version sources are
  `Directory.Build.props` and `zharp.iss`, and release-please owns both.
