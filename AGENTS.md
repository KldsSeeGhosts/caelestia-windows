# Caelestia for Windows

This repository ports Caelestia's original Qt/QML shell to Windows using the
Windows Quickshell backend developed for ii-windows. Read `windows/README.md`
and `windows/ROADMAP.md` before implementation.

- Preserve upstream history, copyright notices, licenses, and recognizable
  component structure. Keep Windows adaptation localized and explain upstream
  changes. `upstream` is Caelestia; `origin` is this private repository.
- Prefer original Caelestia components and motion over visual approximations.
  This project uses Qt Quick/QML and C++ plugins. The Rust/Windows Composition
  constraints of the separate ksg-shell repository do not apply here.
- Treat `windows/sources.lock.json` and the Quickshell gitlink as the dependency
  pins. Update them together after reviewing the change. Do not edit the
  dependency without committing its changes to an appropriate backend fork.
- Use topic branches. Do not force-push `main`. Do not enable inherited Linux
  release workflows or publish packages as part of routine repository work.
- Run native Windows tooling in PowerShell. Linux cross-compilation belongs in
  Ubuntu-24.04 under WSL2. Read upstream commands before adapting them.
- Initial prototypes must use isolated configuration and state. Desktop takeover,
  autostart, taskbar changes, and tiling must be opt-in. Keep one active tiling
  manager during live tests and preserve existing application sessions.
- Keep credentials and authentication outside the repository. Use Windows'
  existing lock screen and UAC; do not implement a replacement credential UI.
- Keep status honest: an importable component, a running prototype, and a
  validated shell release are separate milestones. Record the runtime, source
  revisions, commands, and observed results for each compatibility claim.
- Archive evidence under `windows/validation/` as the README, `result.json`
  and matrix files, logs, and screenshots. Do not copy staged QML sources or
  per-run `sources.json` manifests; the recorded source revision reproduces
  them. Leave existing archives unchanged, since their records reference them.
- Run the environment check after changing pins or setup instructions:
  `powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json`.
  It is a prerequisite report, not a successful build or runtime test.
