# Windows port handoff, 2026-10-26

Caelestia for Windows is the user's live desktop shell. It replaced ksg-shell
on 2026-10-26 and runs round 5b, installed as an in-place update over round 4
with the profile kept. Earlier handoffs are in this file's git history.

## Where the code is

Both repositories use the same branch model as the user's other forks:

| Branch | Purpose |
| --- | --- |
| `ksg/dev` (default) | Integration line. Feature branches merge here. |
| `main` | Stable: the build installed on the user's PC. Fast-forward it from `ksg/dev` after a live install is verified. |
| `upstream` | Mirror of the upstream project: caelestia-dots/shell `main`, or nunreasonable/quickshell `master` for the backend. |
| `t3/<topic>`, backend `windows/<topic>` | Short-lived feature branches from `ksg/dev`. Delete them after merging. |

As of this handoff, both `main` and `ksg/dev` are at round 5b. The backend
fork is KldsSeeGhosts/caelestia-quickshell-windows, remote `caelestia` in
`windows/deps/quickshell`, at `c1177c2`. In progress: `t3/tiling-gaps`, with
backend `windows/tiling-gaps`, for the tiling gaps and focused-window border.

A merge into `ksg/dev` that changes the backend moves the Quickshell gitlink and
`windows/sources.lock.json` together, to a commit on the backend's `ksg/dev`.
Unmerged experiments are kept as `archive/*` tags, not branches.

Both repositories are private. They go public only when the user decides, as a
clean upstream-style export without `windows/validation`, tests and agent
reports. See `RELEASE-CHECKLIST.md`.

## Live install

- Prefix: `%LOCALAPPDATA%\Programs\caelestia-windows`. Profile:
  `%LOCALAPPDATA%\caelestia-windows`, holding `config\shell.json`,
  `config\windows.json` and `config\keybinds.json`.
- Control it with `Start-Caelestia.ps1 -Command Start|State|Quit|Restart`
  from the prefix. `Watch-DesktopShell.ps1` restarts it after a crash.
- Update from a build: quit normally, then run
  `windows/scripts/Install-Caelestia.ps1 -BuildRoot <worktree>\windows\.local\build -Prefix <prefix> -ProfileRoot <profile>`,
  then start it. Do not uninstall or reset the profile.
- Settings in `windows.json`: `hideTaskbar` true, `restartOnCrash` true,
  `wallpaperEngine.enabled` auto. In `shell.json`, interactive tiling
  (`include: ["exe:*"]`, dialogs, PiP and Wallpaper Engine float), gaps 10/10.
  The ksg-shell settings are imported.
- The ksg-shell backup is in
  `%LOCALAPPDATA%\caelestia-windows-switchover\ksg-backup-20261026-023909`.
  ksg-shell's HKCU Run entry `ksg-shell` is **still present**, so ksg-shell
  starts at sign-in. Swap it with `Install-Caelestia.ps1 -Autostart` once the
  user approves.

Checked live on round 5b:
- The bar (left) and border (top, right, bottom) are reserved as AppBars and
  released for fullscreen.
- The keyboard status shows `en` with Caps Lock and Num Lock.
- Google Sans Flex is the UI font.
- The dynamic scheme is ready (real caelestia CLI in the profile venv).
- Wallpaper Engine lists 253 items, and the colours follow its wallpaper.
- All controls are on.
- The `qs` process uses about 458 MB of private memory.

## Open work, in order

1. **Tiling gaps and focused-window border** (`t3/tiling-gaps`, based on the pre-cleanup `08c34968`; merge it into `ksg/dev`). This follows
   Caelestia's Hyprland defaults: a 20-DIP outer gap for a lone window,
   otherwise 10, with 10 between windows. It also adds a 1 px focused-window
   border in the scheme primary through `DWMWA_BORDER_COLOR`, restored on quit.
   Maximized windows keep Windows semantics. Install it live as an update and
   check it visually.
2. Swap autostart from ksg-shell to Caelestia, with the user's approval.
3. A full runtime soak on the installed shell (ERM-533). The round 5 fixes
   are merged.
4. Polish pass 2, from the user's live feedback. The user is the final judge
   of fidelity against upstream Caelestia.
5. Upstream sync (ERM-536). Upstream's `refactor/adopt-lib` branch moves the
   scheme, wallpapers and visualiser to C++ and may replace our versions.
6. A final usage tally (Gemini 3.8 Flash) and the public release export.

## Working rules

- Build first: get features built and merged, and keep smoke tests light.
  Hardening and cleanup come later.
- The default builder is Codex `gpt-6.1-sol`, high reasoning, default service
  tier (not fast mode).
- Keep the live status page current:
  `windows/.local/status_refresh.py`, then
  `windows/.local/reports/live/publish.py --log "..."`. Both are local and
  untracked.
- Linear project:
  [Caelestia Windows](https://linear.app/ermin-zeherovic/project/caelestia-windows-c69c05fa35b7).
- Only one tiling manager may be active on the real desktop. Agents must not
  touch the live install, profile, taskbars or work areas. The orchestrator
  installs builds live.
