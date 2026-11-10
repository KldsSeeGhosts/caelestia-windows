# Contributing to Caelestia for Windows

AI-assisted and hand-written contributions are both welcome. Contributors are
responsible for understanding, reviewing and testing what they submit. Parts of
the Windows port were written with AI assistance under the maintainer's
direction and review. Describe material AI assistance in your contribution and
verify generated code, dependencies, attribution and documentation.

## Build

Use native Windows PowerShell and the toolchain in
[windows/NATIVE-BUILD.md](windows/NATIVE-BUILD.md). It documents prerequisite
setup and `windows/scripts/Build-Prototype.ps1`; do not run the inherited Linux
installer on Windows. Python is required for colour generation, whose packages
live in a profile-local virtual environment.

```powershell
git submodule update --init --recursive
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

The environment report checks prerequisites; it does not prove a build or
runtime pass. Run it again after changing dependency pins or setup instructions.

## Test

Run the fast, SDK-free regression suite before building:

```powershell
powershell -NoProfile -File windows/scripts/Test-Validation.ps1 -Suite Unit
powershell -NoProfile -File windows/scripts/Test-Validation.ps1 -Suite Packaging
```

These use Windows PowerShell, Node 24 and Python 3.12. They cover source and
documentation checks, JavaScript logic, quota providers, lifecycle, settings
import, versioned installation, rollback and scheme-runtime safety. Tests use
synthetic data, local fixture servers and temporary profiles, never your live
accounts or desktop. Packaging checks run separately because they exercise
timeouts and recovery rather than returning immediately.

Build once, then run the Qt/offscreen regressions and production smoke with
your actual Qt prefix. Add `-PluginTests` to `Build-Prototype.ps1` to build the
native plugin regression targets as CI does; run those with CTest as described
in the coverage guide below.

```powershell
$qt = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.3\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-Validation.ps1 `
    -Suite Services -BuildRoot <build> -QtPrefix $qt
powershell -NoProfile -File windows/scripts/Test-Validation.ps1 `
    -Suite Shell -BuildRoot <build> -QtPrefix $qt
powershell -NoProfile -File windows/scripts/Test-Smoke.ps1 `
    -BuildRoot <build> -QtPrefix $qt
```

`Test-Smoke.ps1` is the production smoke command for public CI and contributors. It
stages the production graph from `windows/shell/sources.json`, runs the built
`qs.exe` on the offscreen QPA under a temporary profile, and waits for every
drawer's first frame. It does not install, start the live shell or touch its
profile, services, taskbar, registry or autostart. It exits 0 on pass and 1 on
failure, prints a one-line summary, and keeps the run directory on failure.
Allow up to 90 seconds for a cold start. See
[windows/NATIVE-BUILD.md](windows/NATIVE-BUILD.md#smoke) for the build context.
See [validation coverage](windows/tests/README.md) for colour-worker tests,
installed-release runner support, safe test isolation and the suites not yet
restored from the historical validation work.

Use
[the live checklist](windows/docs/LIVE-CHECKLIST.md) for installed-shell checks
with exclusive desktop ownership. For packaging changes, run:

```powershell
powershell -NoProfile -File windows/scripts/Test-InstallLicenses.ps1 `
    -BuildRoot windows/.local/build -QtPrefix $qt
```

This installs and updates an isolated temporary prefix, verifies notice bytes,
and uninstalls it without launching the shell or enabling autostart.

Record exact commands, source/runtime revisions, results and limitations.
Keep logs and screenshots outside the source checkout, redact private data,
and attach relevant evidence to the pull request instead of committing it. Smoke is not
proof of live input, device control, mixed-DPI motion or a complete release.
Desktop takeover, autostart and tiling require explicit opt-in; use isolated
profiles and one active tiler, preserving other application sessions.

For documentation changes, run the privacy gate before opening the pull
request:

```powershell
powershell -NoProfile -File windows/scripts/Test-PublicDocs.ps1
```

It fails on private tracker references, personal paths, agent assignments and
links that do not resolve inside the repository or to a public URL.

## Branches, commits and the two repositories

Branch topic work from `main`, the default branch, and open pull requests
against it. `main` requires a pull request and the `Windows validation` check,
and it rejects force pushes and deletion. Release tags matching `v*` identify
the exact verified package source and are immutable once created.
[REPOSITORY-POLICY.md](windows/docs/REPOSITORY-POLICY.md) records the active
rulesets, the required backend check and the admin recovery bypass.
Use `windows: <description>` commit subjects for this port.
Keep changes focused, follow nearby QML/C++/PowerShell style, and include
behavior, validation, side effects and known gaps in the pull request.
Do not publish packages as part of routine development.
The upstream Linux workflows were removed; add Windows CI rather than
restoring them.

The public repositories begin with reviewed source snapshots. Earlier private
development history and discussions are not part of these repositories.
Never push branches, tags or history from an old private clone to these public
remotes. Keep personal data, credentials and internal-only references out of
commits from the start; squashing a branch does not purge retained GitHub data.

- [caelestia-windows](https://github.com/KldsSeeGhosts/caelestia-windows)
  contains the preserved upstream UI, Windows adapters, plugins, tooling and
  docs. `upstream` refers to Caelestia; `origin` refers to the port.
- [caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows)
  contains backend changes. Commit backend work there first. Review and make
  that revision available in the backend fork before advancing this repo.
  Update `windows/deps/quickshell`'s gitlink and
  `windows/sources.lock.json`'s `quickshell.revision` together in one port
  commit. Preserve the fork's upstream attribution and license notices.

The M3Shapes gitlink and its manifest entry must likewise agree. Do not
silently edit dependency checkouts or advance pins to uncommitted code.
Keep upstream changes localized and explain why they are needed.

Record each upstream review in
[windows/docs/UPSTREAM-SYNC.md](windows/docs/UPSTREAM-SYNC.md). It lists the
exact compared revisions and the classification of every commit since the last
adopted baseline. Append a dated section for a new comparison instead of editing
an earlier one.

Before merging coordinated backend changes, test both immutable commits with
[exact-pair integration](windows/ci/PAIR-INTEGRATION.md). Candidate mode uses a
separate backend clone and records integration-only provenance, never a
rewritten release lock. After the backend merges, advance both shell pins
together and obtain new pinned-pair receipts for the shell PR and its final
main-push SHA.

## Report an issue

Use this port's bug or feature template in
[Issues](https://github.com/KldsSeeGhosts/caelestia-windows/issues).
For bugs, include the Windows edition/build (`winver`), shell and backend
revisions (or installed `install.json` and `licenses/sources.lock.json`),
monitor layout and DPI, steps, expected/actual behavior, and whether another
shell or tiler was running. Describe enabled takeover and service controls.

Installed logs are under `%LOCALAPPDATA%\caelestia-windows\logs\` by default;
supervisor logs are under the profile's `runtime\supervisor-<id>\`.
Source-run logs are under `windows\.local\build\logs\`. Custom profiles use
their own paths. Redact credentials, personal notification content and other
private data before attaching logs. Read
[the user guide](windows/docs/USER-GUIDE.md) for recovery instructions.
