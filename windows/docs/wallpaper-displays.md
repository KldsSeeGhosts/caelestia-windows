# Wallpaper displays in Nexus

Wallpaper & style has an "Apply next wallpaper to" selector below its preview
and picker buttons. It starts on "All displays". The same selector appears
above the wallpaper grid. Its choice survives navigation into categories and
back within that Nexus window. Browse captures the choice before opening its
asynchronous dialog.

"All displays" replaces every local display's wallpaper and clears individual
overrides. A specific display changes only that display. The selector uses
Quickshell's unique display names and captures the native physical target ID.
Disconnecting a display or reusing its name cannot redirect an outstanding pick
to a different display. Each display row names its current image or Wallpaper
Engine project. Engine summaries describe saved selections, not proof of a
rendered frame.

Fresh profiles reuse `state/wallpaper/desktop.json` version 1, with the existing
shared `wallpaper` field and physical-ID-keyed `monitors` map. A display without
an override falls back to the shared pick, then the bundled image. Existing
profiles keep their released behavior and persist choices through Windows,
while ignoring Explorer's virtual-desktop switch wallpaper broadcasts so
Caelestia picks survive workspace switches. There is no new config key or
migration.

Launcher mouse, keyboard and Choose wallpaper actions apply to all displays
when there are no individual choices. Once individual images or different
Wallpaper Engine projects exist, launcher picks target the launcher's display
to preserve the other choices. Use Nexus's explicit "All displays" option to
return to a shared wallpaper. Launcher previews remain local to its display
and do not change a committed wallpaper.

## Wallpaper Engine

The existing integration toggle and status group now sit below the appearance
controls in Wallpaper & style. Services no longer includes them. Search routes
for Wallpaper Engine and wallpaper displays lead to Wallpaper & style. The
toggle still calls the same facade, preserves `windows.wallpaperEngine` keys,
and stops or resumes desktop playback on all displays without quitting the
engine.

A Nexus project pick follows the selector, including "All displays". The bridge
resolves all connected physical displays against Wallpaper Engine's saved
mapping before dispatching any `openWallpaper -location` commands. An absent
or ambiguous mapping rejects the request without guessing a `MonitorN`.
`--monitor` remains available to existing bridge callers. A process failure
after dispatch can leave a partial result; the error reports failure to apply
to every display. There is no automatic retry or rollback of engine selections.

## Dynamic colours

There is one shell-wide colour scheme, not one per display. Applying a local
wallpaper updates dynamic colours without a shell reload, including a pick for
just one display. Existing profiles also follow wallpaper changes made in Windows.
At startup or when the selected display disconnects, the shell falls back to
the first connected display with a usable saved pick on fresh profiles, or to
Windows' default wallpaper on existing profiles. If no image is available,
the bundled wallpaper supplies it. When Wallpaper Engine integration is on
and the engine owns the desktop, or the shell sees its wallpaper beneath the
icons, the configured `windows.wallpaperEngine.monitor` project preview supplies
the colours. An idle engine process with integration off does not change the
colour source. Changing the picker target does not change the palette-monitor key.

Fixed colour schemes stay fixed. In the launcher wallpaper picker, highlighting
a wallpaper previews its dynamic colours without changing the saved wallpaper,
palette, or colours exported to other apps. Closing the picker restores the
applied colours. Cloud placeholders do not preview until opened.

Dynamic themes use the upstream palette by default. Enable **Tint backgrounds**
under **Wallpaper & style** to use more wallpaper colour in shell backgrounds
and containers. This is `windows.wallpaperSurfaceTint` in `shell.json` and
does not change accent or text colours.

## Owner acceptance

Local verification uses offscreen QPA, disposable profiles and recording
wallpaper/process boundaries. It does not change the live shell, Windows
wallpaper or Wallpaper Engine.

On the owner's desktop, check:

- A fresh shared pick from Nexus, launcher mouse, launcher keyboard and Choose
  wallpaper changes every connected display.
- Selecting a named display changes only it. Restart preserves both choices.
  The display rows agree with the desktop, and "All displays" replaces them.
- Browse retains its target if Nexus moves while the dialog is open. Removing
  or replacing that display rejects the pick instead of changing another one.
- Wallpaper Engine search opens Wallpaper & style. Toggle, status and playback
  behavior match the old Services controls. A project pick respects both an
  individual target and "All displays", including managed display mappings.
- With distinct images, dynamic colours follow the source policy above.
  Launcher highlights preview colours without saving them. Fixed schemes stay
  fixed. Reconnect, handback and launcher preview do not overwrite unrelated
  display choices.
