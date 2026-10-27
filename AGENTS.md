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
- Use topic branches. Do not force-push `main` or publish packages as part of
  routine repository work. The upstream Linux workflows were removed; add
  Windows CI rather than restoring them, and keep them deleted during merges.
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
- Do not commit new logs, screenshots or run archives. Attach evidence to the
  pull request and keep only a short note of the commands, revisions and
  results in the repository. Leave existing `windows/validation/` archives
  unchanged until the pre-publication cleanup.
- Run the environment check after changing pins or setup instructions:
  `powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json`.
  It is a prerequisite report, not a successful build or runtime test.

## Parallel work cadence

Several threads may work at once. Each task follows the same cycle:

1. Start in a new worktree on a topic branch from `origin/dev`: `t3/<topic>`,
   plus `windows/<topic>` from the backend's `dev` when the backend changes.
   Never work directly in another thread's worktree or on `dev` or `main`.
2. Implement, build and test inside that worktree. Builds and tests may run in
   parallel; anything touching the live desktop may not (see below).
3. Commit, push and open a PR into `dev`. Before merging, rebase onto the
   current `origin/dev`. If another task moved the Quickshell gitlink or
   `windows/sources.lock.json` meanwhile, merge the backend branches and move
   both pins again.
4. After the merge into `dev` (and later the fast-forward of `main` once the
   live install is verified), clean up in the same session: remove the
   worktree, delete the local branch and delete the remote branch, in both
   this repository and the backend fork. Check that the worktree is clean and
   its commits are in `origin/dev` first; never delete unmerged work.
   On Windows, folders that `git worktree remove` cannot delete because of
   long paths are removed with `Remove-Item -LiteralPath '\\?\<path>'`.

Only one thread at a time may install a build live, restart the live shell or
run live tests, because there is one install, one profile and one tiler.
Coordinate that through the orchestrating thread.

## Computer use

Delegate all computer use (driving the desktop, apps or the live shell through
GUI automation, screenshots for checks) to a Codex agent on GPT 6.1 Terra.
Other agents, including the orchestrator, do not operate the desktop
themselves. The single-controller rule above still applies: one computer-use
agent at a time, started by the orchestrating thread.
