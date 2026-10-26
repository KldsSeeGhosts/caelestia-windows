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

## KSG settings migration implementation, 2026-10-26

Implemented on `t3/ksg-migration` from `origin/t3/combined-modules`
(`6026f947`). No push, PR, Linear operation, native shell launch, desktop
takeover or change to KSG Shell was performed.

- Added `windows/scripts/Import-KsgShellSettings.ps1`. Default operation
  prints a merged JSON overlay without writing; `-Summary` prints a safe
  mapping report. `-BaseFile`, `-OutFile` and `-DryRun` support review and
  explicit output. Existing output requires `-Force` and is backed up
  byte-for-byte before atomic replacement. KSG profile output is refused.
- Added `windows/docs/MIGRATING-FROM-KSG-SHELL.md`, covering schema sources,
  exact mappings, unsupported preferences, one-tiler switch-over and rollback.
- Audited KSG source revision `85bd3d85` read-only and M3 reference
  `5777a246`. Native KSG has no saved wallpaper, theme/accent, editable
  keybinds or user app-rule lists. Its rules and tiler chords are compiled
  in. M3 uses environment opt-ins, not `shell.json`, and exposes no
  configurable gap/padding. Those preferences are reported for manual
  switch-over, not misrepresented as working JSON settings.

Real-settings dry run under Windows PowerShell 5.1.26100.9711:

| Source | Result |
| --- | --- |
| Bar enabled | `bar.persistent=true` |
| Show date | `bar.clock.showDate=true` |
| Tray icon | `bar.entries[id=tray].enabled=true` |
| Keyboard/Bluetooth/network/volume/power icons | `kbLayout`/`bluetooth`/`network`/`audio`/`battery` status entries enabled |
| OSD | `osd.enabled=true` |
| Tiling enabled; gap/padding | Saved `true`, 10/10 DIPs; summary only, not enabled or written |
| Warnings/existing Caelestia base | None / absent |

Nine source preferences mapped. The current profile also contains dock pins
and historical backups, which have no supported destination and are not
copied. All four KSG profile files retained their hashes and the one existing
KSG process retained its PID through the smoke. No source values resembling
tokens, pin launch commands, wallpaper paths or personal paths are archived.

Quick file-only smoke passed: false values, id-based list merge, preservation
of unrelated fields/nested arrays/nulls, filtering of unknown source values,
tiling defaults/clamping, dry-run, overwrite refusal, byte-identical backup,
idempotence and source overwrite protection. Commands:

```powershell
powershell -NoProfile -File windows/scripts/Test-KsgSettingsImport.ps1
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1 -Summary
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

Evidence: `windows/validation/2026-10-26-ksg-settings-import/`. The prerequisite
report confirms matching backend pins but missing native build tools on the
ordinary PATH. This PowerShell-only change needs no C++/QML rebuild.
Production-profile loading, interactive tiling and full replacement remain
integration/runtime gates, not claims established by this smoke.
