# Wallpaper Engine facade

The combined host starts `WallpaperEngine.qml` at startup. The standard-library
Python bridge discovers Steam via HKCU `Software\Valve\Steam\SteamPath`, reads
`steamapps/libraryfolders.vdf` and `appmanifest_431960.acf`, and checks the running
process list. No Steam or workshop installation path is hardcoded.

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
      "enabled": "auto",
      "picker": "engine",
      "monitor": "Monitor0"
    }
  }
}
```

`enabled` accepts `false`, `true` or `"auto"` (default). Auto activates when the
installation and process are detected. `picker` accepts `"engine"`, `"files"` or
`"both"`; its default is engine while WE is running, files otherwise. `monitor`
defaults to `Monitor0`, WE's primary monitor; set e.g. `Monitor1` to match a bar on
another monitor. An unknown monitor yields no palette rather than silently
sampling another display. `services.smartScheme` still controls smart
light/dark/variant selection.

The prototype launcher regenerates its isolated config each run. To supply these
settings at launch, pass `-WindowsConfigPath <json-file>` to
`Start-ShellPrototype.ps1 -Combined`; it copies that file's `windows` object into
the isolated sidecar. Runtime edits to that file are watched. The pinned C++
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

## Background ownership and remaining presentation gate (#146)

While WE owns the desktop, the Windows background host has no screens and
`DesktopLayer.enabled` stays false. The guard starts closed during discovery
and follows WE starting/stopping. It also yields when WE integration is
disabled. The desktop clock is disabled along with the wallpaper because
layering a Caelestia WorkerW clock above WE has not been validated. Disabling
integration never claims the desktop over a known running external owner.

This is an ownership guard, not visible-output readiness. `snapshot.running`
only checks process names; `selectedwallpapers` is saved configuration and a
successful `openWallpaper` CLI exit acknowledges a request, not a rendered frame.
`DesktopLayer.active` only says an Explorer desktop host exists. None of these
can establish first-frame presentation, coverage or readiness on either monitor,
and `MonitorN` is not mapped to a Quickshell screen identity.

Consequently, switching wallpapers while WE stays running does not toggle this
guard: Caelestia's background is already absent throughout. The bridge cannot
cover a gap between WE frames. Waiting for the next config write or adding a
sleep would not make that handoff safe. A complete seamless bidirectional
handoff still needs backend evidence of per-monitor presentation and validated
fallback layering below WE. Do not hold a visible Caelestia host over WE in the
meantime. Process start/stop remains bounded by the existing status scan; a helper
timeout cannot establish whether external output has stopped.

Windows keeps WallpaperImpl's texture provider alive between its own image
transitions, rather than recreating the shader input at capture time (#139).
This restores the original Windows allocation behavior, at the cost of retaining
one full-screen layer per own-wallpaper surface. It is a shell-transition
safeguard, not a claim that it caused WE's live flash.

Brightness feedback is separate from brightness state: initial discovery,
unchanged route queries, failed reads and HDR/route baseline changes only resync
the slider. Actual same-route observed changes, hardware events and accepted
user adjustments still open the OSD on their own screen. Audio feedback is
unchanged. This avoids the native `WM_SETTINGCHANGE` -> route query -> synthetic
zero/restored level -> OSD path without muting real brightness observations.

### Serialized Windows live check (Terra)

Native Windows rendering, WE output and the installed shell are not testable on
the macOS implementation host. Before accepting #146:

1. Record the running shell PID and supervisor crash count without exposing
   profile contents. With WE running, repeat static -> animated -> static
   selections several times, including rapid changes, on both monitors. Check
   each monitor for Windows-desktop flashes, blank frames and unsolicited OSD.
   Capture cropped evidence on the evidence branch.
2. Exercise Caelestia's own static-image transitions and interrupted transitions
   on both monitors. Verify the previous image remains until the next is ready.
3. Under the authorized serialized QA session, check WE already running at shell
   startup, WE absent/stopped, start/stop, locked/partial config, missing helper
   and helper timeout. Do not describe process/CLI success as frame readiness.
4. Verify actual brightness shortcuts/sliders and hardware changes still open
   only the relevant screen's OSD, including changes to zero. Repeated unchanged
   settings/query notifications, failed reads, HDR route baseline changes and
   resets must not open it. Check volume/mute OSD still works.
5. Confirm the same shell PID and zero additional supervisor crashes throughout.
   Seamless WE presentation remains an open gate if any flash persists.

Scope limits: this reads persisted selected wallpapers, not rendered frames or
playlist transitions WE has not persisted. No Steam downloads, WE startup,
autostart, taskbar changes, config writes or desktop takeover are performed.
