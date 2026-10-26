# Combined modules implementation

Implemented locally on `t3/combined-modules`, based on
`origin/t3/combined-prototype` (`2ca906db`). No backend rebuild, dependency pin
change, push, PR, Linear update or evidence archive was created.

## What works

- `-Combined -Live` enables all existing service control gates and labels the
  control window Live controls. Default Combined is read-only; both smoke modes
  suppress writes. Live also enables tray interception and permits notification
  dismissal/app-open after explicit listener consent.
- All original dashboard tabs, including user/date/calendar/weather/resources,
  media metadata and transport, CPU/RAM/GPU/disk/network performance. Backend
  `SystemMonitor`/`SystemStats` supply native samples. Weather uses upstream HTTP.
- Utilities with facade-backed Wi-Fi/Bluetooth and shell-local do-not-disturb.
- Original notification sidebar/history, popups and core toasts.
- Full launcher navigation with apps/actions, a basic arithmetic provider,
  original wallpaper carousel and a native wallpaper file picker. Desktop
  wallpaper writes use the backend's existing `Wallpaper.setWallpaper` API.
- Session commands use the adapter allowlist. Destructive actions require the
  pending action's Confirm button in the control window.

## Stubbed or limited

- Dynamic scheme/variant generation: no `caelestia scheme` CLI or matugen in the
  supplied runtime. Wallpaper applies without changing the fixed palette.
- M3Shapes is absent from the supplied build. Decorative outlines use neutral
  round surfaces; expressive shapes/morphing are unavailable.
- Lyrics/audio analysis and profile-image editing have missing native services
  or API support. Unimplemented quick toggles are hidden; profile-image clicks
  report unavailability. Idle inhibition, the recorder and Windows lock are
  implemented in the utilities slice below.
- Basic calculator replaces excluded Qalculate; units are unsupported.
- Native capability/permission limits remain visible. No fake brightness route,
  temperature, notification permission or successful native write is supplied.
- Workspaces, ActiveWindow, Hypr, tiling and AppBar code were not changed.

## Validation

Quick smoke launches passed in read-only and Live-smoke modes with the supplied
Qt 6.11.2/backend build, without triggering native writes. They open all four
dashboard tabs, utilities, notification history, popouts, launcher and toasts.
The arithmetic smoke checks `2*(3+4)^2 = 98`. Dashboard screenshots were inspected
for layout. The environment prerequisite check reports matching dependency pins;
build tools are not on the ordinary PATH, and the supplied build was reused.
Actual native writes, tray interception, player transport and
notification consent were not exercised, so these remain wired capabilities,
not claims of end-to-end live validation.

## Launch

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build -Combined -Live
```

Omit `-Live` for read-only mode. Add `-Smoke` for the automatic no-write smoke.
Details and remaining limitations: `windows/combined-prototype/README.md`.

## Utilities slice: idle inhibitor, recorder, lock

Implemented on `t3/utilities-native`, branched from `origin/t3/combined-modules`
(`6026f947`). No backend C++ change, dependency pin change, push or PR. The
supplied build was reused unchanged (backend gitlink `525786fc`).

- **Idle inhibitor.** The original `IdleInhibit` card keeps
  `RuntimeState.inhibitIdle` and the "Active since" chip. Windows has no Wayland
  `IdleInhibitor`, so `daemons/IdleInhibit.qml` runs
  `helpers/KeepAwake.ps1` as a child while the toggle is on. The helper holds
  `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
  ES_SYSTEM_REQUIRED)` on its own thread, exits when the toggle stops (Quickshell
  kills its children) or when the shell PID is gone, and an unexpected exit
  clears the toggle instead of leaving a false "active" state.
- **Screen recorder.** `services/Recorder.qml` keeps the upstream
  `start/stop/togglePause/running/paused/elapsed` contract and drives ffmpeg:
  `where ffmpeg` availability, `%USERPROFILE%\Videos\Caelestia`, gdigrab
  `desktop` at 30 fps into H.264 MP4, and `q` on ffmpeg's stdin to finalise the
  file (6 s bounded kill fallback). The original card layout is kept; region and
  audio capture, pause, and the Linux recordings list/delete modal are not
  offered, and a missing ffmpeg shows `Unavailable: ffmpeg was not found on
  PATH.` in the card's one-line status.
- **Lock.** No gap: the pinned backend's `Session::lock()` already calls
  `LockWorkStation()` (`windows/deps/quickshell/src/windows/system/session.cpp`),
  and the combined launcher's `Lock` action resolves `["lock"]` through the
  original session adapter, only with Live session actions. No lock screen,
  credential UI or extra process was added.

Both cards are enabled in the combined profile and visible in read-only runs,
but act only with `CAELESTIA_COMBINED_LIVE=1` outside smoke; smoke asserts that
neither process exists. `-Combined -Smoke` and `-Combined -Live -Smoke` both
passed (exit 0, 32.6 s / 32.2 s, no QML warnings). Direct checks outside smoke:
the helper stayed alive with the execution state set; the exact ffmpeg command
with `-t 2` produced a valid MP4; a throwaway harness drove the real Recorder
singleton through probe → mkdir → start → stop, and `ffprobe` confirmed a
finalised clip (test file deleted). Limitations: fullscreen-only capture, no
recordings list, keep-awake verified by process lifetime rather than an elevated
`powercfg /requests` read, and no real lock was performed.
