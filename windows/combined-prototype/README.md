# Combined shell prototype

The bounded Windows host stages the original Caelestia bar, dashboard, launcher,
utilities, notification history, popups and toasts over the reviewed facades in
`windows/services`. Configuration and state stay in the isolated combined profile.

## Launch

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build -Combined -Live
```

Omit `-Live` for read-only observation. The control window labels the mode and
provides panel buttons, screen selection, wallpaper selection and preview exit.
Hover the top edge for the dashboard, bottom edge for the launcher, and right
edge for notification history. The logo also opens the launcher. Full screen is
an explicit control-window toggle; it does not reserve work area or start tiling.

`-Live` enables the existing audio, hardware brightness, media, Wi-Fi, Bluetooth,
power-profile, app-launch, tray activation and session action gates. It also
enables the tray hook. Notification mirroring, Windows dismissal and app-open
are permitted, but listener access is requested only by the history panel's
explicit button. No access request happens at startup. Destructive session
buttons create a pending request; Confirm/Cancel appear in the control window.
Commands remain confined to the session adapter allowlist.

`-Combined -Smoke` and `-Combined -Live -Smoke` both suppress native writes,
launches, session dispatch, tray interception and notification mirroring. They
load all dashboard tabs, utilities, history, the launcher, status popouts,
notifications and a toast, and exit. The supplied build is reused unchanged.
When the scheme runtime is available the smoke run also asserts that the
launcher's scheme and variant providers loaded from the bridge (26 scheme rows
and 9 variants with the current scheme set) and that the generated palette was
applied.

## Available components

- Original bar logo, clock, tray, status icons, popouts, session drawer and OSD.
- All four original dashboard tabs: Dashboard, Media, Performance and Weather.
  The dashboard contains the original user/date/calendar/weather/resource/media
  layout. Performance reads CPU, RAM, GPU and volumes from the backend's
  `SystemMonitor`, and network throughput from `SystemStats`, with original
  network sparklines. Missing temperatures display Unavailable. Dashboard content
  scales down to fit the bounded host. Weather retains upstream HTTP requests
  and uses only profile-local cache storage.
- Original utilities wrapper and quick-toggle layout, limited to Wi-Fi,
  Bluetooth and shell-local do-not-disturb. Hardware controls follow their
  facade's availability and write gate.
- Original sidebar notification history, grouping, dismissal and mirror-access
  UI, plus original notification popups and core `Toaster` rendering.
- Original launcher search, keyboard navigation, app rows, action rows and
  wallpaper carousel. Type `>` for actions, `> calc 2*(3+4)^2` for arithmetic,
  or `> wallpaper ` to browse images in `%USERPROFILE%/Pictures/Wallpapers`.
  Set `CAELESTIA_WALLPAPER_DIR` before launching to use another folder. The
  Choose wallpaper action/control-window button opens a native image picker.
  Applying a wallpaper uses the existing `Quickshell.Windows.Wallpaper` API and
  requires Live controls. Highlighting an image never applies it.
- Dynamic Material You colours follow the wallpaper. The profile-local Python
  runtime runs the upstream `caelestia` CLI's own scheme generator
  (`materialyoucolor` quantize/score plus the Material dynamic schemes) and
  writes `state/caelestia/scheme.json`; `Colours.qml` watches that file, so the
  shell recolours live. Applying a wallpaper regenerates the dynamic palette
  (respecting `services.smartScheme`). The launcher's `> scheme ` and
  `> variant ` rows work, and the `Light mode`/`Dark mode` actions regenerate
  the palette. The runtime is created on first combined launch inside the
  isolated profile (see below); the first launch needs `py` and network access.
- Calculator supports arithmetic, powers, parentheses, pi/e and basic math
  functions. Clicking/accepting copies the result in Live mode. Its external
  calculator button opens Windows Calculator in Live mode.

## Dynamic colours and the profile-local scheme runtime

`Start-ShellPrototype.ps1 -Combined` calls `Install-SchemeRuntime.ps1`, which
provisions `scheme/venv` under the combined profile (never the repository or the
user's ordinary Python packages) with `pillow==13.0.0`,
`materialyoucolor==3.0.4` and the upstream `caelestia` CLI pinned at
`5e804b10`. The installer also places a Windows `fcntl` shim in the venv and
copies `win_scheme.py` into the profile. Use `-SkipSchemeRuntime` to skip
provisioning and the generator entirely. A failed provision is cached in
`scheme/runtime.json`; delete that file or run `Install-SchemeRuntime.ps1
-ProfileRoot <profile> -Force` to retry.

`win_scheme.py` imports the CLI's scheme/material modules but deliberately skips
its theme writer (Linux-only `fcntl`, Hyprland sockets, dconf, `/dev/pts` and
`killall`). The Windows shell is the only theme consumer. Upstream's symlink
wallpaper state is replaced with ordinary `path.txt`/`thumbnail.jpg` files
because Windows symlinks need extra privileges. All state, cache and config
writes are forced below `combined-prototype-profile`; the bridge refuses to run
without `CAELESTIA_PROFILE_ROOT`.

If provisioning or generation fails, `schemeRuntime` is false in the run result
and the shell keeps its fixed Caelestia palette. Switching variant or mode while
a static scheme is selected switches to the wallpaper-derived dynamic palette
when a wallpaper is known, so those rows always do something visible.

## Still unavailable, and why

- Workspaces, ActiveWindow, tiling, Hypr dispatch and AppBar are outside this
  implementation. Their existing adapters are unchanged.
- Dynamic colours depend on the profile-local Python runtime. Without `py`,
  network access on first launch, or a working `materialyoucolor`/CLI install,
  the generator reports unavailable and wallpaper changes retain the fixed
  palette. The port does not run matugen or the CLI's Linux theme application
  pipeline, so generated colours do not propagate to GTK, Hyprland, terminals,
  Discord or other upstream targets. Static scheme previews come from the CLI's
  bundled scheme data.
- Expressive M3 shape outlines and morphing require the native M3Shapes plugin,
  which is absent from the supplied build. A combined-only round-surface shim
  keeps the original layout and children; it does not claim the original shapes.
- Lyrics, beat tracking and audio visualisation depend on excluded upstream
  native services. Cover art, metadata, player selection and transport remain.
- Profile picture editing is unavailable; its click reports this in a toast.
- Idle inhibition lacks a lifetime-scoped inhibition API in the existing backend.
  Recorder, VPN and Linux-specific quick toggles are hidden.
- Qalculate is excluded from the portable build. The arithmetic provider is a
  small expression parser, without Qalculate's units or arbitrary expressions.
- Hardware and backend capability limits still apply: missing DDC/WMI brightness
  routes, unavailable sensors, denied network access and notification-listener
  permission are not treated as successful operations. Software gamma remains
  off. Tray contents depend on the Live hook and actual native observation.

## Staging boundaries

`Stage-ShellPrototype.ps1` unions the M1 manifest, service slice manifests and
`combined-prototype/sources.json`. Combined overrides are explicit. Battery,
Bluetooth and Tray facades retain their `Windows*` staged names to avoid QML
component/singleton name collisions. Dashboard statistics fill the upstream
`Caelestia.Services` contracts using Windows APIs already in the backend; the
unbuilt Linux native services are never imported. Combined-only adapters replace
Linux process calls in profile pictures, calculator, wallpaper, colours, scheme
generation and launcher providers. The real upstream `SchemeItem`/`VariantItem`
replace the apps-only stubs. Other prototype entry points retain their existing
sources and gates.

This remains a prototype. Smoke validates loading and layout without exercising
native writes, destructive actions, tray interception or notification consent.
The scheme bridge is exercised separately from the smoke boundary because it
writes only inside the isolated profile.
