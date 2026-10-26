# Windows keyboard shortcuts

Implemented on `t3/global-shortcuts`, based on `origin/t3/combined-modules`
(`6026f947`). Backend changes are committed on the local
`windows/global-shortcuts` branch in
`D:\AiStack\caelestia-windows\windows\.local\qs-shortcuts`. Nothing was pushed,
no PR or Linear item was created, and no evidence archive was written.

## What works

- `Quickshell.Hyprland`'s `GlobalShortcut` is backed by the Windows hotkey
  manager. Modifier combinations use `RegisterHotKey`; Super combinations and
  the lone-Super tap use a `WH_KEYBOARD_LL` hook. The hook is installed only
  while at least one hook-backed bind exists.
- A lone Super tap opens/closes the Caelestia launcher, matching upstream's
  `SUPER + SUPER_L` release bind. The hook consumes the Super release while the
  shell owns the tap, so Explorer's Start menu does not open for that tap. When
  no launcher bind exists, the hook is not installed and Super passes through.
- The original daemon shortcut names are preserved (`launcher`, `showall`,
  `dashboard`, `session`, `sidebar`, `utilities`, `launcherInterrupt`,
  `clearNotifs`, `toggleDnd`, `mediaToggle`, `mediaPrev`, `mediaNext`,
  `mediaStop`, `brightnessUp`, `brightnessDown`) plus Windows `volumeUp`,
  `volumeDown`, and `volumeMute`.
- The combined prototype now instantiates the original shortcut daemon surface.
  Its Windows adapter targets the prototype's selected `ScreenState`; it does
  not depend on the unavailable `Hypr.focusedMonitor`.
- Registered hotkeys and the low-level hook are released when the shell exits.
  A synthetic `Ctrl+Alt+C` probe owned by the shell became registerable again
  immediately after the process exited.

## Default binds

Shipped in `defaults/windows/keybinds.json`:

| Keys | Action |
| --- | --- |
| Super (tap) | Launcher |
| Super+K | Show launcher, dashboard, OSD and utilities together |
| Super+Shift+D | Dashboard |
| Super+N | Notification sidebar |
| Super+Shift+U | Utilities |
| Ctrl+Alt+End | Session menu (Ctrl+Alt+Delete is reserved by Windows) |
| Ctrl+Alt+C | Clear notifications |
| Super+Shift+N | Do not disturb |
| Ctrl+Super+Space, XF86AudioPlay | Play/pause |
| Ctrl+Super+Equal, XF86AudioNext | Next track |
| Ctrl+Super+Minus, XF86AudioPrev | Previous track |
| Ctrl+Super+Backspace, XF86AudioStop | Stop (no-op: the facade reports stop unsupported) |
| XF86AudioRaiseVolume / XF86AudioLowerVolume | Output volume (repeating) |
| XF86AudioMute, Super+Shift+M | Mute output |
| Ctrl+Alt+Page Up / Page Down | Brightness (repeating) |
| Super+L | Lock Windows (`rundll32 user32.dll,LockWorkStation`) |

The map is configurable without rebuilding:

- Put `keybinds.json` in the shell configuration directory (`CAELESTIA_CONFIG_DIR`,
  next to `shell.json`). This is the preferred per-shell override.
- Or use `%LOCALAPPDATA%\caelestia\windows\keybinds.json`.
- Or set `CAELESTIA_WINDOWS_KEYBINDS` to an explicit file for an isolated run.
- Start a user file with `{"extends": "defaults", "binds": [...]}` and override
  an entry with `"base": "global:caelestia:launcher"`. The file is watched and
  reloads the binds without restarting.

The backend change that makes the config-directory location work:

- `configFile` in the default map is resolved against `CAELESTIA_CONFIG_DIR`
  before the per-user data location.
- The configuration directory is watched, so creating the override applies it.
- `CAELESTIA_WINDOWS_KEYBINDS` overrides both paths.
- `Hotkeys.trigger(name)` exposes programmatic delivery for shells and tests.

## Build and smoke

Build (in this worktree only, Qt 6.11.2 / clang-cl 20.1.8 / Ninja):

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts" `
    -BuildRoot (Join-Path (Get-Location) 'windows\.local\build')
```

Backend and portable plugins built cleanly. The shortcut smoke launched the
combined prototype without `-Smoke`, waited for it to settle, sent a synthetic
lone Super tap, and then stopped it. Observed:

- `Loaded 23 binds from .../defaults/windows/keybinds.json`
- `Keyboard hook installed.`
- `Bind "Super" "global" phase 3`
- `CAELESTIA_SHORTCUT name=launcher launcher=true`
- no QML/runtime `ERROR` or `FATAL` line
- `Ctrl+Alt+C` was registered while running (`RegisterHotKey` refused a second
  owner) and registerable again after exit.

The stock `-Combined -Smoke` run currently fails its pre-existing
`notification popup did not render` assertion in this environment. The same
failure reproduces after stashing every change in this task, so it is not caused
by the shortcut work.

Windows ignores synthetic Win-key input for the Start menu itself, so the
visual Start menu could not be exercised with `SendInput`. After the shell
exited, a synthetic Ctrl+Esc did open SearchHost (and closed on Escape),
confirming desktop input was healthy. The hotkey registrations were released and
the low-level hook is process-scoped, so a real Super press reaches Start again.

## Backend branch and commit

- Repository: `D:\AiStack\caelestia-windows\windows\deps\quickshell`
- Worktree: `D:\AiStack\caelestia-windows\windows\.local\qs-shortcuts`
- Branch: `windows/global-shortcuts`
- Commit: `d44760b27945d945387cb8ba165d8739afb2d1ff`
  (`windows: resolve keybinds overrides from the shell config`)
- Base: `caelestia/windows/m3-dpi-unaware-placement` (`b92e9fa`)
- Shell pin: `windows/sources.lock.json` and the `windows/deps/quickshell`
  gitlink are updated to that commit.

The backend commit is local to the worktree; it was not pushed to the
`caelestia` remote.

## Shell commit

`d931193d` (`windows: ship default global shortcuts and the combined shortcut
daemon`), on `t3/global-shortcuts`.

## Known limits

- `Ctrl+Alt+Delete` is a Windows secure-attention sequence and cannot be bound;
  `Ctrl+Alt+End` is the substitute.
- Windows laptop brightness keys do not arrive as stable virtual keys, so the
  default uses `Ctrl+Alt+Page Up/Down`; both entries can be changed in the map.
- `mediaStop` is wired, but the pinned media facade reports stop unsupported, so
  it does not claim a successful native stop.
- The root production `shell.qml` already instantiates the original shortcut
  daemon. This task validates the Windows combined prototype path; the full
  production shell host remains a separate milestone.
