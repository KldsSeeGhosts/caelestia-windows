# Contributing to Caelestia for Windows

AI-assisted and hand-written contributions are both welcome. Contributors
are responsible for understanding, reviewing and testing what they submit.
The Windows port itself was built with substantial AI assistance: Claude
orchestrated work implemented in part by GPT, GLM, DeepSeek and Gemini agents,
under the maintainer's direction and review. Describe material AI assistance
in your contribution and verify generated code, dependencies and attribution.

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

Build first, then run the public smoke with your actual Qt prefix:

```powershell
$qt = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-Smoke.ps1 `
    -BuildRoot <build> -QtPrefix $qt
```

`Test-Smoke.ps1` is the single smoke command for public CI and contributors. It
stages the production graph from `windows/shell/sources.json`, runs the built
`qs.exe` on the offscreen QPA under a temporary profile, and waits for every
drawer's first frame. It does not install, start the live shell or touch its
profile, services, taskbar, registry or autostart. It exits 0 on pass and 1 on
failure, prints a one-line summary, and keeps the run directory on failure.
Allow up to 90 seconds for a cold start. See
[windows/NATIVE-BUILD.md](windows/NATIVE-BUILD.md#smoke) for the build context.

Run the relevant `windows/scripts/Test-<Service>Service.ps1` offscreen fixture
for service changes, using `-QtPrefix $qt -BuildRoot <path>` from a disposable
temporary working directory. Use
[the live checklist](windows/docs/LIVE-CHECKLIST.md) for installed-shell checks
with exclusive desktop ownership. For packaging changes, run:

```powershell
powershell -NoProfile -File windows/scripts/Test-InstallLicenses.ps1 `
    -BuildRoot windows/.local/build -QtPrefix $qt
```

This installs and updates an isolated temporary prefix, verifies notice bytes,
and uninstalls it without launching the shell or enabling autostart.

Record exact commands, source/runtime revisions, results and limitations.
Logs normally live under `windows/.local/build/logs/` or the harness-specific
validation directory. Attach logs and screenshots to the pull request instead
of committing them, and leave existing `windows/validation/` archives intact.
Smoke is not proof of live input, device control, mixed-DPI motion or a complete
release. Desktop takeover, autostart and tiling require explicit opt-in; use
isolated profiles and one active tiler, preserving other application sessions.

## Branches, commits and the two repositories

Branch topic work from `dev`, the default branch, and open pull requests
against it. `main` follows the latest verified release, and `upstream` mirrors
the upstream project. Use `windows: <description>` commit subjects for this port.
Keep changes focused, follow nearby QML/C++/PowerShell style, and include
behavior, validation, side effects and known gaps in the pull request.
Do not force-push `main` or publish packages as part of routine development.
The upstream Linux workflows were removed; add Windows CI rather than
restoring them.

- [caelestia-windows](https://github.com/KldsSeeGhosts/caelestia-windows)
  contains the preserved upstream UI, Windows adapters, plugins, tooling and
  docs. `upstream` refers to Caelestia; `origin` refers to the port.
- [caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows)
  contains backend changes. Commit backend work there first. Review and make
  that revision available in the backend fork before advancing this repo.
  Update `windows/deps/quickshell`'s gitlink and
  `windows/sources.lock.json`'s `quickshell.revision` together in one port
  commit. Preserve the fork's upstream history and license notices.

The M3Shapes gitlink and its manifest entry must likewise agree. Do not
silently edit dependency checkouts or advance pins to uncommitted code.
Keep upstream changes localized and explain why they are needed.

## Report an issue

Use this port's bug or feature template in
[Issues](https://github.com/KldsSeeGhosts/caelestia-windows/issues).
For bugs, include the Windows edition/build (`winver`), shell and backend
revisions (or installed `install.json` and `licenses/sources.lock.json`),
monitor layout and DPI, steps, expected/actual behavior, and whether another
shell or tiler was running. Describe enabled takeover and service controls.

Installed logs are under `%LOCALAPPDATA%\caelestia-windows\logs\` by default;
supervisor logs are under the profile's `runtime\supervisor-<id>\`.
Source-run logs are under `windows\.local\build\logs\` and harness output
directories. Custom profiles use their own paths. Redact credentials,
personal notification content and other private data before attaching logs.
Read [the user guide](windows/docs/USER-GUIDE.md) for recovery instructions.
