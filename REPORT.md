# Windows desktop background implementation

Branch: `t3/background`, based on `origin/t3/combined-modules`
(`6026f9475e99393be5d85c49b2367f1c36e3632e`). Work performed alone.
No push, PR, Linear update, backend rebuild, dependency change or evidence
archive. The shared build was read-only; all run artifacts are ignored under
`windows/.local/background-smoke`.

## Implementation

- Stages the original `modules/background` wallpaper, desktop clock, and
  visualiser component. The original wallpaper capture/shader transition
  implementation is preserved. Static images use a Windows-only portable
  `Visual` adapter because the supplied build excludes native Multimedia.
- `WindowsBackground` opts into the existing backend `DesktopLayer` API.
  `-Background` enables it; `-DesktopIcons Behind|Replace` chooses placement
  below or above desktop icons. Replace covers the icons without hiding them
  through Explorer or changing persistent settings.
- The backend mapping was already implemented at pinned revision
  `525786fc81f13346cb196dca5ab356f89ad707a5`: `WlrLayer` maps directly to
  `PanelLayer`, desktop embedding reparents nonexclusive background panels,
  and `desktop_host.cpp` supports legacy WorkerW and the 24H2+ child WorkerW
  layout after Progman `0x052C`. No C++ patch or backend worktree was needed.
- The original screen `Variants` follows `Screens.screens` and per-monitor
  enablement; the Windows wrapper filters to one selected screen during smoke.
  If no desktop host exists, the wrapper creates no background windows.
- The same `Wallpapers` service used by the picker now exposes `current`,
  preview/stopPreview and desktop wallpaper change observation. Starting the
  background never changes the configured Windows wallpaper.
- The visualiser hook loads the original component only when an `Audio.cava`
  provider exists. This task does not add audio analysis or fake values.
- Small upstream changes expose a configurable background screen set, use the
  direct `exclusionMode` property supported by Windows, and name the wallpaper
  and clock objects for the bounded smoke check.
- `-RunRoot` separates writable staging/profile/logs from `-BuildRoot`.
  `-Combined -Background -Smoke` runs the new short desktop check; the existing
  panel smoke stays unchanged when background is omitted.

## Quick validation

Reused Qt 6.11.2 and the existing backend/portable plugin build at
`D:\AiStack\caelestia-windows\windows\.local\build` on Windows build 26300.
The worktree's implementation changes were exercised over the base revision
above. No source copies or run manifests were archived.

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix C:\Users\Ermin\AppData\Local\caelestia-dev\Qt\6.11.2\msvc2022_64 `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build `
    -RunRoot "$PWD\windows\.local\background-smoke" `
    -Combined -Background -Smoke
```

Repeated once with `-DesktopIcons Replace`. Both passed with exit code 0 and
no warning/error diagnostics. Runtime was 12.3s / 11.8s including startup;
the check ran after 10s. Each observed exactly one `MAG321UX OLED` background,
2560x1440 logical pixels at native 150% scaling, with wallpaper and clock ready.
Backend logs confirm actual parenting behind icons to HWND `0x10216` and
above icons to HWND `0x1016a`, respectively.

Desktop screenshots were captured with Cua:
`windows/.local/background-smoke/during.png`, `replace-during.png`, and
`after.png`. They show the clock occluded by the ordinary editor window and the
existing wallpaper reappearing after exit. The editor covers most of the
desktop, so only the exposed part of the clock is visible in desktop captures.
A requested temporary editor frame change was immediately managed by the
existing tiler; its original frame was restored and verified. No tiling
settings were changed.

Before/after desktop snapshots match monitor work areas, taskbar state and
Explorer presence. Explorer PID 9252 and the installed `ksg-shell` PID 24108
were preserved; no test-owned Quickshell process remained after exit.

`Test-Environment.ps1 -Json` with explicit Qt/runtime paths reports matching
dependency pins and the existing runtime. The ordinary PowerShell PATH lacks
CMake/Ninja/compiler, so `nativeToolchainReady` is false. This is a prerequisite
report, not a new build claim. `git diff --check` passed.

## Limits and integration

Hotplug, Explorer restart, mixed-DPI monitor transfer, live picker writes,
actual visualiser output and interactive desktop icon behavior were not tested.
The backend and original screen model implement their lifecycle paths, but
these smoke runs are not a validated shell release. Video wallpaper support
remains unavailable in the portable image adapter.

The colour-scheme, visualiser and production-entry agents may also touch the
combined manifest, entrypoint and Wallpapers service. Preserve these background
entries and the `Wallpapers.current` contract during integration. Production
can instantiate `WindowsBackground` using its opt-in environment contract;
ordinary runs cover every enabled monitor.

---

# Earlier combined modules implementation

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
- Lyrics/audio analysis, profile-image editing, idle inhibition and recorder
  have missing native services or API support. Unimplemented quick toggles are
  hidden; profile-image clicks report unavailability.
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
