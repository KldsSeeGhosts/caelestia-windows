# Wallpaper Engine implementation

Implemented on `t3/wallpaper-engine`, based on `origin/t3/dynamic-scheme`
(`6abba7ba`). Final implementation revision: `27ae336c`. All commits use
`windows:` messages. No pushes, PRs, Linear changes, subagents, dependency
updates or native rebuilds.

- Added a Windows service facade with Steam registry/library/manifest discovery,
  running-process detection, active per-monitor config resolution, project
  metadata and previews. FileView watches WE's config; five-second read-only
  discovery catches process changes, workshop installs and atomic replacements.
- Current Monitor0 preview feeds the existing real Caelestia Material generator.
  `services.smartScheme` is respected; Pillow samples animated previews at frame
  zero. The generated scheme is loaded live by Colours.
- The original launcher carousel supports WE titles/previews and the requested
  engine/files/both picker modes. Default is engine when WE runs. Explicit Live
  selection requests the official CLI using an argument array; the watcher
  confirms selection before generating its palette. Scheme mode/variant actions
  use the preview rather than attempting to decode project.json.
- `windows.wallpaperEngine.enabled` defaults to auto; optional `monitor`
  defaults to Monitor0. Windows settings use watched isolated
  `config/windows.json` because the pinned C++ shell schema rejects a windows
  key. `-WindowsConfigPath` supplies this object without rebuilding the shared
  binary. See `windows/services/wallpaperengine/README.md`.
- Carried the WindowsBackground adapter from `origin/t3/background` (`08055887`)
  with a fail-closed external-owner guard. It disables the entire desktop host,
  including the clock, while WE runs. Clock layering above WE is unvalidated.
  The ordinary dynamic-scheme branch has no background host to instantiate;
  preserve this guarded adapter when merging the background branch.
- Fixed combined carousel Loader lifetimes exposed by the new picker smoke.

Validation reused the supplied build at
`D:\AiStack\caelestia-windows\windows\.local\build` (Qt 6.11.2, backend
`525786fc`, CLI `5e804b10`). Final `-Combined -Smoke` passes from clean committed
source in 35.7 seconds without warnings/errors. It reads “Autum In Japan Pixel
Art”, generates primary `#f9b7a3`, and renders 253 workshop items in the picker.
A short isolated background probe passes with zero background windows,
DesktopLayer inactive and clock off. A GIF preview generates primary `#acc9ea`.
Both current WE monitor selections remain exactly unchanged; no CLI switch was
invoked. The environment prerequisite report was also recorded.

Evidence, screenshot, commands and limits:
`windows/validation/2026-10-26-wallpaper-engine/README.md`.
Live CLI switching, external wallpaper transitions, restart/recovery and clock
layering remain unvalidated. This is quick smoke evidence, not a validated shell
release.

## Previous combined modules implementation

The previous dynamic-scheme work was implemented locally on `t3/dynamic-scheme`, based on
`origin/t3/combined-modules` (`6026f947`). No backend rebuild, dependency pin
change, push, PR, Linear update or evidence archive was created.

## Dynamic colours (this change)

The Windows port now follows the wallpaper. `Start-ShellPrototype.ps1 -Combined`
provisions a profile-local Python virtual environment under
`<build>/combined-prototype-profile/scheme` (never the repository or the user's
ordinary Python packages) with `pillow`, `materialyoucolor==3.0.4` and the
upstream `caelestia` CLI pinned at `5e804b10...`. `windows/scripts/scheme/win_scheme.py`
imports the CLI's own scheme/material modules (the same quantize/score and
Material dynamic-scheme code used by `caelestia scheme set` / `caelestia
wallpaper -p`) and writes `state/caelestia/scheme.json` in the isolated profile.
The CLI's Linux theme writer is deliberately not run: it needs `fcntl`,
Hyprland, dconf, `/dev/pts` and `killall`, and on Windows the QML shell is the
only theme consumer. A small `fcntl` shim is installed for package import
compatibility; upstream symlink state is replaced with ordinary files because
Windows symlinks require extra privileges.

What is wired:

- Picking a wallpaper (launcher carousel or the native file picker) applies it
  through the existing `Quickshell.Windows.Wallpaper` API and regenerates a
  dynamic scheme. `services.smartScheme` selects smart mode/variant.
- `services/Colours.qml` watches the scheme JSON, applies all 74 palette keys
  live and reports the loaded palette. It keeps the upstream palette contract
  (`palette`, `tPalette`, `light`, `layer()`, `load()`, `setMode()`) and falls
  back to the fixed Caelestia defaults when no scheme exists.
- The launcher's original `SchemeItem`/`VariantItem` rows are staged. The
  `> scheme ` rows list the CLI's 26 bundled name/flavour combinations and the
  `> variant ` rows the 9 Material variants. Selecting either calls the bridge.
- `Light mode` and `Dark mode` actions were added; both regenerate the palette.
  Switching mode/variant while a static scheme is selected switches to the
  wallpaper-derived dynamic palette when a wallpaper is known, so the rows
  always change something visible.
- `-SkipSchemeRuntime` opts out. Provisioning or generation failure is
  non-fatal: `schemeRuntime` is false in the run result, the shell keeps the
  fixed palette, and the failure is reported in the shell log.

## What works

- `-Combined -Live` enables all existing service control gates and labels the
  control window Live controls. Default Combined is read-only; both smoke modes
  suppress native writes. Live also enables tray interception and permits
  notification dismissal/app-open after explicit listener consent.
- All original dashboard tabs, including user/date/calendar/weather/resources,
  media metadata and transport, CPU/RAM/GPU/disk/network performance. Backend
  `SystemMonitor`/`SystemStats` supply native samples. Weather uses upstream HTTP.
- Utilities with facade-backed Wi-Fi/Bluetooth and shell-local do-not-disturb.
- Original notification sidebar/history, popups and core toasts.
- Full launcher navigation with apps/actions, a basic arithmetic provider,
  original wallpaper carousel and a native wallpaper file picker.
- Dynamic Material You palette from the wallpaper, live recolour, scheme and
  variant rows, and light/dark regeneration (details above).
- Session commands use the adapter allowlist. Destructive actions require the
  pending action's Confirm button in the control window.

## Stubbed or limited

- Dynamic colours need `py`, network access on first launch, and a successful
  `materialyoucolor`/CLI install. Without those the generator is unavailable and
  the fixed palette remains. Generated colours are not propagated to GTK,
  terminals, Discord, Hyprland or other upstream theme targets; the Windows
  shell is the only consumer.
- Smart mode/variant follows `services.smartScheme` when a wallpaper is picked.
  A manually chosen static scheme is honoured until a mode/variant change, which
  switches back to the dynamic palette.
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

- `-Combined -Smoke` passes with the supplied Qt 6.11.2/backend build
  (`passed: true`, exit 0). It asserts 26 scheme rows and 9 variants from the
  bridge, loads the generated scheme (74 palette keys), and exercises every
  panel as before. The scheme runtime was `available: true` in the run result.
- Manual generation from sample images through the same bridge the picker calls:
  `assets/wallpaper.webp` produced a dark tonal-spot palette with primary
  `#b4c7ed`; `assets/dino.png` produced dark/neutral with primary `#c7c7c7`;
  a light-mode regeneration produced surface `#fafafa` (primary `#5f5f5f`).
  Smoke runs after each generation logged the matching
  `CAELESTIA_SCHEME_LOADED ... primary=...`, proving the palette changed and
  loaded. Screenshots show the recoloured dark launcher and light sidebar.
- First-run provisioning took about 20 s; cached launches add about 0.4 s. A
  genuine first-run check (existing runtime and scheme state moved aside) ran
  `-Combined -Smoke` with `schemeRuntimeMessage=provisioned`, created the CLI's
  default scheme, applied 74 palette keys and passed.
- Actual wallpaper writes, player transport, tray interception and notification
  consent were not exercised in smoke, so these remain wired capabilities, not
  claims of end-to-end live validation.

## Launch

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build -Combined -Live
```

Omit `-Live` for read-only mode. Add `-Smoke` for the automatic no-write smoke,
or `-SkipSchemeRuntime` to keep the fixed palette. Pick a wallpaper from the
launcher (`> wallpaper `) or the control window to regenerate colours; use
`> scheme `, `> variant `, or the Light/Dark actions to change the palette.
Details and remaining limitations: `windows/combined-prototype/README.md`.
