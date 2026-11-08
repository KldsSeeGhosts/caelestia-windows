# Wallpaper Engine facade

The combined host starts `WallpaperEngine.qml` at startup. The standard-library
Python bridge discovers Steam via HKCU `Software\Valve\Steam\SteamPath`, reads
`steamapps/libraryfolders.vdf` and `appmanifest_431960.acf`, and checks the running
process list. No Steam or workshop installation path is hardcoded.

When the integration is disabled, or enabled but Wallpaper Engine is not
installed or not running, the shell selects its own wallpaper and derives its
palette from that image. A running engine still owns a visible wallpaper
window: the pinned backend places marked backgrounds below every visible
foreign child and refuses an above-icons embed while one exists, so the engine
covers the shell's image until the process quits. A fresh profile starts on
`assets/wallpaper.webp`; provenance is recorded once in
`state/caelestia/wallpaper/profile.json` before any other start-up writer, and
the chosen source is recorded in `state/caelestia/wallpaper/desktop.json`. An
upgrade keeps the Windows wallpaper it already showed, whether or not the
optional colour runtime produced a palette. See the configuration reference for
the record, the comparison baseline and the missing-key rule.

The active config is
`<user>.general.wallpaperconfig.selectedwallpapers.MonitorN.file`. Saved/recent
layouts are deliberately excluded. Each selected media/package path resolves to
the adjacent `project.json`, whose title and preview feed the launcher and real
Caelestia scheme generator. `FileView` watches `config.json`; a complete read
immediately resolves the selected projects in read-only status mode, so a
wallpaper change does not wait for the workshop-wide catalogue walk. The same
status scan also catches atomic replacements and process changes, with a full
catalogue refresh every 20 idle scans or when state changes. The scan runs every 15 s only
while WE is detected and running; it backs off to 60 s when WE is absent or
stopped (a start is still noticed within a minute) or the last scan failed, and
stops when no helper is configured, or when the integration is disabled and no process is known to be running (ownership is still handed back when it quits).
Invalid/partially written configs retain the last good catalogue and report an
error, but independently observed process start/stop still updates the ownership
guard. If the process scan itself fails, the existing failure policy retains
last-known process state, or allows the shell fallback if there has not yet been
a good scan. That startup fallback cannot prove an external owner is absent.
Animated previews are sampled at frame zero with Pillow.

Windows-only settings live in the isolated `config/windows.json` sidecar:

```json
{
  "windows": {
    "wallpaperEngine": {
      "enabled": false,
      "picker": "engine",
      "monitor": "Monitor0"
    }
  }
}
```

`enabled` defaults to `false` when the key is absent. A fresh install therefore
shows the bundled Caelestia wallpaper and does not depend on Wallpaper Engine;
the Nexus Services page opt-in writes `true`. A saved `true` keeps the
integration on. The older `"auto"` value is still accepted for existing
profiles and activates automatically when the installation and process are
detected. The old default is distinguishable from absence: `"auto"` is a
present string and stays on, while a missing key stays off. Loading never
rewrites a saved value; the toggle writes `true` or `false` only when the user
changes it. `picker` accepts `"engine"`, `"files"` or `"both"`; its default is
engine while WE is running, files otherwise. `monitor` defaults to `Monitor0`,
WE's primary monitor; set e.g. `Monitor1` to match a bar on another monitor. An
unknown monitor yields no palette rather than silently sampling another
display. `services.smartScheme` still controls smart light/dark/variant
selection.

Put these settings in the profile's `config/windows.json` sidecar. Runtime
edits to that file are watched. The pinned C++
config schema rejects unknown keys in `shell.json`, so the sidecar preserves
the requested `windows.wallpaperEngine` namespace without a config plugin
rebuild.

The carousel keeps project identity separate from the preview image. Selecting
an engine item requests the official
`wallpaper64.exe -control openWallpaper -file <project.json> -monitor N` with an
argument array, never a shell command. Only discovered workshop projects are
accepted. Both QML and Python enforce the existing Live/non-smoke write gate.
An accepted request is not proof of success: the config watcher observes the
actual selection and only then regenerates the scheme.

## Background ownership and remaining presentation gate

On a supporting backend, the background windows and their clocks stay mounted
in the desktop host beneath visible foreign wallpaper children. Only a refused
embed or a legacy backend without underlay support withdraws them. Native
placement uses window rectangles and sibling order, not persisted `MonitorN`
labels: an external window covers only the desktop regions it occupies.
Requested Replace-icons embedding also defers to a visible foreign child in
the wallpaper host, even when the optional helper fails.

The underlay retains the last usable own wallpaper, or the bundled fallback.
Engine selection previews still drive palette generation, but no longer
replace that underlay merely because the process or saved selection changed.
An explicit own-file pick updates the fallback. This source is retained in the
current QML generation, not persisted across shell restarts.

This is an ownership guard, not visible-output readiness. `snapshot.running`
only checks process names; `selectedwallpapers` is saved configuration and a
successful `openWallpaper` CLI exit acknowledges a request, not a rendered frame.
`DesktopLayer.active` only says an Explorer desktop host exists. None of these
can establish first-frame presentation, coverage or readiness on either monitor,
and `MonitorN` is not mapped to a Quickshell screen identity.

This protects gaps where a foreign window is absent, hidden or does not cover
a region. It does **not** protect a region covered by an opaque foreign HWND
that paints a placeholder or the Windows wallpaper before its renderer is
ready. Native sibling order and clipping are identical before and after that
renderer presents. `underlayActive` is host-wide foreign-window presence, not
per-monitor content readiness. Native ordering and clipping checks cannot
establish Wallpaper Engine scanout.

That is a remaining capability blocker for , not evidence that seamless
handoff is complete. A correct stronger handoff needs renderer cooperation
with monitor identity, output generation and presentation acknowledgement, or
a controlled rendering/composition path that retains the old output until
the next output is ready. No such capability is supplied by the current
bridge or the documented
[Wallpaper Engine CLI](https://help.wallpaperengine.io/en/functionality/cli.html).
This is an inference from that command interface, not a claim about private
Wallpaper Engine internals.
[Windows child-window clipping](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#clipping)
also does not distinguish an opaque placeholder from a wallpaper frame.
Waiting for config, process or window events, or adding a sleep, cannot supply
that missing information. Keeping a shell overlay above the external HWND
would instead risk covering legitimate wallpaper content.

Helper failure also cannot prove that an engine-era system wallpaper is an
own-file choice. Without successful ownership discovery at startup, the
existing system-source adoption path still needs live scrutiny. A reload with
an engine already running has no persisted last-own source. Process start/stop
remains bounded by the existing status scan; a helper timeout cannot establish
whether external output has stopped.

Windows keeps WallpaperImpl's texture provider alive between its own image
transitions, rather than recreating the shader input at capture time.
This restores the original Windows allocation behavior, at the cost of retaining
one full-screen layer per own-wallpaper surface. It is a shell-transition
safeguard, not a claim that it caused WE's live flash.

Brightness feedback is separate from brightness state: initial discovery,
unchanged route queries, failed reads and HDR/route baseline changes only resync
the slider. Actual same-route observed changes, hardware events and accepted
user adjustments still open the OSD on their own screen. Audio feedback is
unchanged. This avoids the native `WM_SETTINGCHANGE` -> route query -> synthetic
zero/restored level -> OSD path without muting real brightness observations.

### Remaining live validation

Seamless Wallpaper Engine presentation is not yet accepted
(the project documentation).
Offscreen rendering and successful process or CLI requests do not establish
what the external wallpaper actually presents. Remaining checks cover:

- Static and animated changes on each monitor, including rapid selections and
  interrupted own-image transitions, without desktop flashes, blank frames or
  unsolicited brightness feedback.
- Startup with the engine present or absent, engine start/stop, partial or
  locked configuration, and helper failure without falsely reporting a ready
  wallpaper frame.
- Genuine brightness adjustments, including zero, producing feedback on the
  relevant screen while unchanged queries, failed reads and route-baseline
  changes remain quiet.

These are outstanding acceptance limits, not a claim that the installed shell
has passed seamless transitions or every hardware-feedback case.

Scope limits: this reads persisted selected wallpapers, not rendered frames or
playlist transitions WE has not persisted. No Steam downloads, WE startup,
autostart, taskbar changes, config writes or desktop takeover are performed.
