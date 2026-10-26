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
- Lyrics, profile-image editing, idle inhibition and recorder have missing native
  services or API support. Unimplemented quick toggles are hidden; profile-image
  clicks report unavailability. Audio visualisation and beat tracking are now
  implemented; see [the audio visualiser report](windows/REPORT-audio-visualizer.md).
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
