# Windows tray prototype

A bounded M2 host for the original Caelestia bar tray. It preserves the original
`Tray.qml` icons, `ColouredIcon` tinting, `TrayItem.qml` sizing and motion, and
`TrayMenu.qml` structure. Nothing here changes taskbar settings, Explorer,
registry, autostart or the notification area.

The native system tray belongs to Explorer. This slice observes it read-only
with backend interception disabled. It never competes for tray ownership and
never activates or clicks a real tray icon during a test.

## Modes

`Start-ShellPrototype.ps1 -Tray -TrayMode <mode>`:

| Mode | Observation | Activation / native menu | Scroll |
| --- | --- | --- | --- |
| `Disabled` (default) | `SystemTray` is never constructed | refused | no-op |
| `ReadOnly` | `CAELESTIA_WINDOWS_TRAY=1`; items observed | refused | no-op |
| `Interactive` | observation plus `CAELESTIA_WINDOWS_TRAY_ACTIVATION=1` | `activate()`, `secondaryActivate()`, `display()` | unsupported |

`-Smoke` always forces activation off (ReadOnly smoke still observes) and is
the only mode used by the
checked-in validation. `Interactive` is an unvalidated explicit opt-in: the
pinned backend reports no per-command result, and its activation/menu paths call
`AllowSetForegroundWindow` for the icon owner, so they can foreground another
application.

Every tray run also forces `QS_WINDOWS_TRAY_HOOK=0`. With that value the backend
does not start its interception thread or schedule Explorer snapshots
(`host.cpp` lines 172-201), so **no tray items are enumerated**: read-only smoke
observes an empty list unless the hook is enabled. The host never enables it.
Interception ownership (the `Shell_TrayWnd`/`TrayNotifyWnd` hook, message
forwarding and `TaskbarCreated` broadcasts) is out of scope and requires a
separate review.

## Fixture preview

`Start-ShellPrototype.ps1 -Tray -TrayMode Disabled -TrayFixture -Smoke` renders
the original components against three plain QtObject items and a small bundled
PNG. It constructs no `SystemTray`, sends no native message, and validates the
original delegate chain (`Tray` → `TrayItem` → `ColouredIcon` → `Colouriser` →
`ImageAnalyser`) including tinting, sizing and the unavailable-menu styling.
Fake items only count method calls; nothing is clicked.

## Backend gaps

Pinned backend `1401042969e4b7ab3cfb314fc76945ab081db3de`:

- `SystemTray` exposes only `items`; there is no readiness, snapshot-complete,
  Explorer-generation or error property (`qml.hpp` lines 16-18). The service
  distinguishes `initializing` (no facade yet), `empty` and `ready(count)`, but
  cannot distinguish "no icons" from "enumeration never ran".
- `hasMenu` is always true while `menu` is always null (`item.hpp` lines
  102-104), so the original semantic `TrayMenu` cannot render. The host routes
  "open menu" to `display()` only under the activation opt-in.
- `display()` ignores the parent window and both coordinates (`item.cpp` lines
  199-210). The host forwards scene coordinates for a future backend and the
  service records that they are ignored.
- `scroll()` is an empty stub (`item.cpp` line 197); the service reports it as
  unsupported and never calls it.
- `ownerAlive()` is not invokable and Explorer identity lives inside the hook
  (`item.hpp` line 90, `hook.cpp` lines 474-487), so a resettled item list is
  observed as a generation change but is not proof of an Explorer restart.

## Build and run

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-TrayService.ps1 -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-TrayPrototype.ps1 -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Tray -TrayMode ReadOnly -Wait
```

Evidence lives in
[`windows/validation/2026-10-25-m2-tray`](../validation/2026-10-25-m2-tray/README.md).
