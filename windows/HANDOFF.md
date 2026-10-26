# Windows port handoff, 2026-10-26

Caelestia for Windows is the user's live desktop shell. It replaced ksg-shell
on 2026-10-26 and runs round 5b, installed as an in-place update over round 4
with the profile kept. Earlier handoffs are in this file's git history.

## Where the code is

Both repositories use the conventional `main`, `dev` and `upstream` branch model:

| Branch | Purpose |
| --- | --- |
| `dev` (default) | Integration line. Feature branches merge here. |
| `main` | Stable: the build installed on the user's PC. Fast-forward it from `dev` after a live install is verified. |
| `upstream` | Mirror of the upstream project: caelestia-dots/shell `main`, or nunreasonable/quickshell `master` for the backend. |
| `t3/<topic>`, backend `windows/<topic>` | Short-lived feature branches from `dev`. Delete them after merging. |

As of this handoff, both `main` and `dev` are at round 5b. The backend
fork is KldsSeeGhosts/caelestia-quickshell-windows, remote `caelestia` in
`windows/deps/quickshell`, at `c1177c2`. In progress: `t3/tiling-gaps`, with
backend `windows/tiling-gaps`, for the tiling gaps and focused-window border.

A merge into `dev` that changes the backend moves the Quickshell gitlink and
`windows/sources.lock.json` together, to a commit on the backend's `dev`.
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

Done since round 5b:
- Tiling gaps, merged into `dev` and `main` (9b2f9529, backend `0876208`).
  A lone tiled window sits 20 DIPs from the frame, and other windows get 10.
  The focused window gets a scheme-coloured border, through
  `windows.tiling.singleWindowGapsOut` and `borderColours`. Measured live at
  20 DIPs. Check the border colour visually when the displays are on.
- Autostart: the HKCU Run entry `CaelestiaWindows` starts the shell. The
  ksg-shell entry was removed; its value is saved as `ksg-shell-run-entry.txt`
  in the switch-over backup.

Remaining:
1. A full runtime soak on the installed shell (ERM-533).
2. Polish pass 2, from the user's live feedback (ERM-540). The user is the
   final judge of fidelity against upstream Caelestia.
3. Live acceptance gates moved to M4. ERM-499 needs a laptop battery; ERM-508
   needs audio device, denial and sleep recovery tested.
4. Upstream sync (ERM-536). Upstream's `refactor/adopt-lib` branch moves the
   scheme, wallpapers and visualiser to C++ and may replace our versions.
5. A final usage tally with Gemini 3.8 Flash (ERM-542) and the public release
   export (ERM-541).

Known quirk: a shell started while every display is off reserves its edges but
draws nothing until the displays wake. Round 5b behaves the same way.

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
