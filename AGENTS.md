# Caelestia for Windows

A port of Caelestia's Qt/QML shell to Windows, on the Windows Quickshell
backend developed for ii-windows. For context, see `windows/README.md` and
`windows/ROADMAP.md`. Open work is tracked in GitHub issues and in the Linear
project "Caelestia Windows".

## Principles

- Ship a complete, working product first; harden it later.
- Write the smallest change that works. Reuse or delete code before adding
  more, and keep hot paths lean.
- Only data loss, crashes or hangs, security or privacy leaks, and anything
  broken in normal use block a merge. Everything else becomes a follow-up
  issue.
- Real use beats simulation. Prefer a short live check over more offscreen
  tests.
- Stay faithful to upstream Caelestia: keep its original components and
  motion. Put Windows changes in adapters under
  `windows/combined-prototype/adapters/`, and keep any edit to an upstream file
  small and commented. Fix platform gaps once, in the backend.
- Report what was and was not verified.

## Repository

- **Remotes:** `origin` is this private repository and `upstream` is
  Caelestia. `gh` defaults to upstream here, so always pass
  `-R KldsSeeGhosts/caelestia-windows`.
- **Branches:** `dev` is the integration line and `main` is the
  live-verified build. Topic branches merge into `dev` by PR. Never
  force-push `main`.
- **Pins:** the Quickshell gitlink and `windows/sources.lock.json` move
  together, to a commit on the backend fork's `dev`.
- **Parallel threads:** each thread works on its own branch and never edits
  another thread's branch or worktree. Update from `origin/dev` before
  merging, and resolve conflicts by keeping both sides.
- **Cleanup:** once your PR merges, delete your worktree and your local and
  remote branches, in this repository and the backend fork.
- **Keep out of commits:** logs, screenshots, run archives and credentials.
  Leave `windows/validation/` unchanged until the pre-publication cleanup.
- **User data:** never log or display it, for example clipboard contents.
  Use Windows' own lock screen and UAC.

## Build and test

- Use PowerShell. Initialise submodules first, then build into a short path,
  because deep paths exceed MAX_PATH:
  `windows/scripts/Build-Prototype.ps1 -BuildRoot C:\b-<topic>`.
- Run test binaries from a disposable temporary directory, never from the
  repository or a home directory.
- After changing pins, run
  `windows/scripts/Test-Environment.ps1 -Json`.

## Live desktop

There is one install, one profile and one tiler, so only one thread at a time
installs, restarts the shell or tests live.

- **Paths:** the prefix is `%LOCALAPPDATA%\Programs\caelestia-windows`. The
  profile is `%LOCALAPPDATA%\caelestia-windows`, with `config\shell.json` and
  `config\keybinds.json`.
- **Install:**
  1. Run `Start-Caelestia.ps1 -Command Quit`.
  2. Run `Install-Caelestia.ps1 -BuildRoot <build> -Prefix <prefix> -ProfileRoot <profile>`.
  3. Start the shell through a one-off interactive scheduled task running the
     HKCU Run entry `CaelestiaWindows`. A shell started from an agent's own
     shell dies with it.
  4. Confirm with `-Command State`. If the shell is not running, read
     `runtime\supervisor-*\watchdog-error.log` in the profile.
- **Opt-in only:** desktop takeover, autostart, taskbar and tiling changes.
  Keep only one tiling manager active.

## Computer use and QA

GPT 6.1 Terra on Codex, at medium reasoning, is the dedicated computer-use and
QA agent. It tests the live shell and changes and does any GUI task, doing the
work itself. Other agents do not operate the desktop.
