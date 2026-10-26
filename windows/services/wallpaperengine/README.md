# Wallpaper Engine facade

The combined host starts `WallpaperEngine.qml` at startup. The standard-library
Python bridge discovers Steam via HKCU `Software\Valve\Steam\SteamPath`, reads
`steamapps/libraryfolders.vdf` and `appmanifest_431960.acf`, and checks the running
process list. No Steam or workshop installation path is hardcoded.

The active config is
`<user>.general.wallpaperconfig.selectedwallpapers.MonitorN.file`. Saved/recent
layouts are deliberately excluded. Each selected media/package path resolves to
the adjacent `project.json`, whose title and preview feed the launcher and real
Caelestia scheme generator. `FileView` watches `config.json`; a five-second
read-only rescan also catches atomic replacements, process changes and workshop
installs. Invalid/partially written configs retain the last good snapshot and
report an error. Animated previews are sampled at frame zero with Pillow.

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

## Background branch integration

This branch is based on `t3/dynamic-scheme`, which does not stage a desktop
background. `adapters/modules/background/WindowsBackground.qml` is carried from
`origin/t3/background` (`08055887`) with the WE guard added, ready for the
background branch's manifest/host to consume when the branches are merged.
Keep this guarded version during that merge. Do not replace the dynamic
`Wallpapers.qml` adapter with the background branch's older adapter.

While WE owns the desktop, the Windows background host has no screens and
`DesktopLayer.enabled` stays false. The guard starts closed during discovery
and follows WE starting/stopping. It also yields when WE integration is
disabled. The desktop clock is disabled along with the wallpaper because
layering a Caelestia WorkerW clock above WE has not been validated. Disabling
integration never claims the desktop over a still-running external owner.

Scope limits: this reads persisted selected wallpapers, not rendered frames or
playlist transitions WE has not persisted. No Steam downloads, WE startup,
autostart, taskbar changes, config writes or desktop takeover are performed.
