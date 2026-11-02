# M1 bar and drawer dependency audit

Static audit for ERM-491/492, 2026-10-25. Inspected checkout
`d83e065a4df4405678dfd8115062dd56211ddef4` on `windows/m1-bar-drawer`;
upstream baseline `2e1c51fa76d94457624b642c678218970aa2517a`; Quickshell
gitlink/lock revision `e8ae0ef124b1c14b547c80d00422d2ffbd423d81`.
Line references below identify the original files at that inspected revision,
before concurrent implementation edits. This document records source requirements, not a successful load or runtime
compatibility result. No application was launched for this audit.

## Selected implementation at handoff

The parent selected a **bounded native window**, superseding the initial
ordinary-window recommendation below. The implementation loads the original
ContentWindow, StyledWindow, Regions, Interactions, Bar/BarWrapper, Clock/Power,
and session Content/Wrapper, with explicit unavailable panel/service adapters.
`windows/shell-prototype/shell.qml` constrains the native window to at most
900x620 logical pixels with an 80-pixel inset through margins. It does not
instantiate Drawers or Exclusions, or enable taskbar/tiling controllers.
Backend-owned desktop support and startup cleanup are separate from a desktop
takeover; see the backend audit and root's validation record for that boundary.

At handoff the parent reported successful smoke runs at 100% and 150% with
no runtime diagnostics and the original icons rendering. This research agent
did not run or independently reproduce those tests. Pointer-driven hover,
focus/dismissal, native monitor/DPI transitions, transparency and lifecycle
acceptance remain separate M1 gates.

For the M1 slice the staging source of truth is
[`windows/shell-prototype/sources.json`](../shell-prototype/sources.json):
42 explicit mappings, plus the entry point and five font/license/provenance
files added by
[`Stage-ShellPrototype.ps1`](../scripts/Stage-ShellPrototype.ps1).
Production stages the separate map in
[`windows/shell/sources.json`](../shell/sources.json).
Relative to the initial set below it adds original:

```text
modules/drawers/ContentWindow.qml
modules/drawers/Regions.qml
components/containers/StyledWindow.qml
components/ClipRect.qml
services/ShellState.qml
services/Screens.qml
```

It also adds platform `bar/popouts/ClipWrapper.qml` and
`drawers/UnavailablePanel.qml` adapters. Audio/Brightness adapters from the
initial defensive proposal are not staged: their branches remain disabled
and the disabled ActiveWindow entry has no Brightness.Monitor type reference.
The selected native graph adds Quickshell.Wayland, Quickshell.Hyprland and
Caelestia.Components to the initial closure. Original ShellState/Screens now
require the Hypr adapter's focusedMonitor/monitorFor and component registration
contracts (`services/ShellState.qml:16-52,79-113`).

Three localized ContentWindow adaptations are present at handoff:
null monitor makes dragMaskPadding zero; the threshold maximum is clamped
with `Math.max(0, ...thresholds)`; exclusionMode is set on the window rather
than the unsupported WlrLayershell attached location. Their original source
locations are :47-58 and :69. The parent owns implementation/validation of
these edits; this audit changed no original QML.

Material Symbols Rounded and Rubik are now explicit process-local assets at
`windows/assets/material-symbols-rounded/MaterialSymbolsRounded.ttf` and
`windows/assets/rubik/Rubik.ttf`, with licenses and pinned hashes in
[`windows/assets/README.md`](../assets/README.md). The initial missing-font
finding below is resolved by this selected implementation.

## Initial recommendation and dependency rationale

The remaining sections preserve the initial minimal proposal and its static
dependency findings. Where that proposal differs from the final implementation,
the selected implementation and actual manifest above take precedence.

Load the original `modules/bar/Bar.qml`, `BarWrapper.qml`, bar `Clock.qml` and
`Power.qml`, and original `modules/session/Wrapper.qml` and `Content.qml`.
Use Clock, Power, and spacers only. Run the original
`modules/drawers/Interactions.qml` inside an isolated ordinary-window host.
Supply nonvisual, explicitly unavailable adapters for the statically named
disabled bar entries, popouts, and unsupported panel contracts.

This route needs no change to these original files. The staged `Panels.qml`
and `bar/popouts/Wrapper.qml` are platform adapters, not the original panels
or popout implementations. Record that distinction in the staging manifest.
That proposed ordinary-window step would not load original ContentWindow or
validate native input regions. The selected implementation above does load
ContentWindow, while keeping M1 acceptance claims bounded to recorded tests.

The original session drawer is the smallest complete content/wrapper pair:

| Candidate | Source-backed assessment |
| --- | --- |
| Session, selected | `modules/session/Wrapper.qml:10-39` uses screen state, Config, Tokens, Anim, and one Loader. `Content.qml:17-131` uses four original IconButtons, keyboard navigation, focus, and one optional GIF. Its only platform service call is `SessionManager.exec(command)` at lines 92-94. |
| Sidebar, defer | `modules/sidebar/Wrapper.qml:12-46` creates `Props` and original Content. Content creates NotifDock at `Content.qml:27-32`. Even an empty notification list retains the static notification delegate graph: `NotifDock.qml:139-145` -> NotifDockList -> NotifGroupList/NotifGroup -> Notif/NotifActionList. Notification types, image effects, lists, icons, and a Notifs adapter remain necessary. `NotifDock.qml:26` also mutates notifications on completion. |
| Dashboard, defer | `modules/dashboard/Wrapper.qml:15-28` immediately creates a FileDialog, uses `Images.validImageExtensions`, and includes profile copying to `~/.face` plus `notify-send` callbacks. `Content.qml:16-47,158-187` declares all four pane Components before filtering enabled tabs. Dash itself statically creates User, SmallWeather, DateTime, Calendar, Resources, and Media (`Dash.qml:17-107`). Disabling media/performance/weather tabs does not sever their type dependencies. |

`Session.Wrapper` retains the original right-edge slide, opacity, unloading
after close, and Tokens easing (`Wrapper.qml:13-39`). Content retains original
button sizes, radius changes, ripple, focus colors, key navigation, and Escape.
The session drawer has **no original hover-to-open option**. It opens via the
original Power button (`bar/components/Power.qml:22`), state/shortcut, or the
right-edge drag branch in Interactions. Bar hover is original and testable.
Do not present a newly invented session-hover gesture as upstream behavior.

## Static resolution and disabled delegates

`Bar.qml:109-110` filters enabled model entries, but its DelegateChooser
declares OsIcon, Workspaces, ActiveWindow, Tray, Clock, StatusIcons, and Power
at `Bar.qml:116-182`. Disabled entries prevent instantiation, not QML type
resolution. The same distinction applies to an inactive Loader with an inline
`sourceComponent`, and to disabled dashboard tab Components.

Qt 6.11.2's [Loader documentation](https://doc.qt.io/qt-6.11/qml-qtquick-loader.html#active-prop)
describes delayed instantiation. Its
[QQmlTypeData implementation](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/qml/qml/qqmltypedata.cpp#L409-L437)
checks errors in resolved type dependencies before creation, and
[type resolution](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/qml/qml/qqmltypedata.cpp#L886-L911)
rejects unresolved imports. Applying those rules to these declarations means
every named delegate type needs a loadable definition even when its row is
disabled. A URL loaded only on demand can form a compilation boundary; another
inline Component does not.

Additional static edges:

- Bar and BarWrapper require the **same** `BarPopouts.Wrapper` type
  (`Bar.qml:18`, `BarWrapper.qml:15`); Interactions requires it too
  (`Interactions.qml:14`). Use one staged module, not independently declared
  lookalike wrapper types.
- Interactions requires `Panels` and `Bar.BarWrapper`
  (`Interactions.qml:16-17`). A plain unrelated Item will not satisfy these
  typed properties. Stage the platform Panels under the exact module/type.
- Bar's JavaScript casts name Tray and StatusIcons even when
  no such row exists (`Bar.qml:27,48,56`). Keep their types available.
- Original ActiveWindow has a typed `Brightness.Monitor` property
  (`components/ActiveWindow.qml:14`). Replacing this disabled *entry contract*
  with a nonvisual adapter removes that nested type requirement; copying the
  original file instead requires it.
- Session's disabled GIF still requires `AnimatedImage` and `QsWindow` types
  (`session/Content.qml:53-68`), but its source expression need not run with
  `paths.sessionGif` empty.

The rejected original entry/popout branches are concrete dependencies, not
just optional service values:

| Original branch | Static files/imports and live contracts excluded by the adapter |
| --- | --- |
| Logo | `bar/components/OsIcon.qml:1-6,22-45` -> `components/Logo.qml` and `components/effects/ColouredIcon.qml`. Logo uses QtQuick.Shapes; ColouredIcon imports Quickshell.Widgets and **Caelestia.Images** and creates ImageAnalyser (`ColouredIcon.qml:3-5,30-34`). OsIcon reads SysInfo.isDefaultLogo/osLogo and clicks ShellState.forActive().launcher. Even fixing isDefaultLogo=true does not remove the statically declared distro-icon branch. |
| Workspaces | `bar/components/workspaces/Workspaces.qml:3-11,94-96,122-135,145-148,163-167,212-216` names OccupiedBg, Workspace, GapMarkers, ActiveIndicator, SpecialWorkspaces. All five sibling files plus Workspaces are needed if retaining that original type. Workspace imports **M3Shapes**, Caelestia.Components, and typed Quickshell.Hyprland monitor/toplevel/workspace objects (`Workspace.qml:3-12,21,30,255`). Workspaces derives ClipRect -> Caelestia.Components.RoundedMask. Hypr must supply workspaces.values, monitors, toplevels, focus/dispatch and filtering helpers. This is much larger than a disabled Workspaces entry contract. |
| Active window | `bar/components/ActiveWindow.qml:3-18,63-76` -> original MaterialIcon/StyledText and utils Icons; uses Brightness.Monitor, Hypr.activeToplevel title/class, window popout state, and title transitions. Icons imports Quickshell.Services.Notifications (`utils/Icons.qml:3-6`). |
| Tray | `bar/components/Tray.qml:3-8,69-74` -> TrayItem; TrayItem's required SystemTrayItem (`TrayItem.qml:4,13`) and ColouredIcon -> Images analyser remain static even when recolour=false. Runtime uses SystemTray.items.values, Status.Passive, activate()/secondaryActivate(), GlobalConfig hidden/substituted icons. |
| Status | `bar/components/StatusIcons.qml:9,67-144` -> status/LockStatus.qml, BluetoothStatus.qml, BatteryStatus.qml. BluetoothStatus imports Quickshell.Bluetooth and requires BluetoothDevice (`BluetoothStatus.qml:6,52`); BatteryStatus imports Quickshell.Services.UPower (`BatteryStatus.qml:2`). StatusIcons additionally reads Hypr locks/layout, Audio sink/source volume/mute and Nmcli active Ethernet/Wi-Fi/strength even though its entry model is filtered. |
| Real popout Wrapper | `bar/popouts/Wrapper.qml:3-11,89-165` names Content, WindowInfo and Nexus; imports Wayland and Hyprland, creates HyprlandFocusGrab and binds WlrLayershell.keyboardFocus. Its disabled Comp loaders do not isolate these type declarations. |
| Popout Content | `bar/popouts/Content.qml:3-9,32-158` names ActiveWindow, Network, WirelessPassword, Bluetooth, Battery, AudioPopout, kblayout/KbLayout, LockStatus and TrayMenu. Its SystemTray model and typed SystemTrayItem remain; KbLayout -> KbLayoutModel imports Quickshell.Io. Network/password content would pull in Nmcli. None is required when all bar popouts are disabled. |
| Detached Nexus/window info | `modules/nexus/Nexus.qml:3-9` -> Pages/NavPane and settings pages; wallpaper selection imports Caelestia.Models plus file dialog (`nexus/pages/wallandstyle/WallpaperSelect.qml:3-15`). `modules/windowinfo/Preview.qml:3-11` imports Wayland/Hyprland for window-preview behavior. These are not justified dependencies for a clock/power bar. |
| Dashboard even with tabs filtered | `components/filedialog/FolderContents.qml:8-9` imports Caelestia.Models and Multimedia; `dashboard/dash/User.qml:4,7` imports M3Shapes and Multimedia; Calendar and Media use M3Shapes. Performance/resource/media children import Caelestia.Services (`dashboard/Performance.qml:7`, `dash/Resources.qml:4`, `dash/Media.qml:7`). Original dashboard needs adapters/types beyond the five portable native modules selected here. |

## Initial exact original QML staging set

Copy the following files byte-for-byte, preserving these relative paths.
No full directory copies and no root upstream `shell.qml`.

```text
components/Anim.qml
components/CAnim.qml
components/StyledRect.qml
components/StyledText.qml
components/MaterialIcon.qml
components/StateLayer.qml
components/ScreenState.qml
components/controls/ButtonBase.qml
components/controls/IconButton.qml
components/controls/CustomMouseArea.qml
modules/bar/Bar.qml
modules/bar/BarWrapper.qml
modules/bar/components/Clock.qml
modules/bar/components/Power.qml
modules/drawers/Interactions.qml
modules/session/Wrapper.qml
modules/session/Content.qml
services/Time.qml
utils/Strings.qml
```

Closure: Power -> StateLayer -> StyledRect/Anim/CAnim; Clock ->
StyledRect/StyledText/MaterialIcon -> CAnim/Anim; session Content ->
IconButton -> ButtonBase -> StateLayer/MaterialIcon; Interactions ->
CustomMouseArea; BarWrapper -> Strings. ScreenState supplies the shared typed
state. Paths and all other platform names below come from isolated adapters.
This set excludes the old dashboard DateTime specimen and ClipRect because
neither is needed by the selected original components.

The exact adapter **destination** set for the initial proposal was:

```text
shell.qml                                  isolated platform host
services/Colours.qml                       fixed complete slice palette
services/Audio.qml                         unavailable wheel-action contract
services/Brightness.qml                    unavailable monitor-action contract
services/Hypr.qml                          unavailable workspace-action contract
utils/Paths.qml                            isolated URL/path contract
modules/bar/components/OsIcon.qml           unavailable disabled entry
modules/bar/components/ActiveWindow.qml     unavailable disabled entry
modules/bar/components/Tray.qml             unavailable disabled entry
modules/bar/components/StatusIcons.qml      unavailable disabled entry
modules/bar/components/workspaces/Workspaces.qml
modules/bar/popouts/Wrapper.qml             unavailable popout contract
modules/drawers/Panels.qml                  host panel contract, real Session.Wrapper
imports/Caelestia/Services/qmldir
imports/Caelestia/Services/SessionManager.qml
```

These are proposed staging destinations, not preexisting implementation source
paths. Keep adapter sources under `windows/`, distinct from original sources;
the parent chooses that source layout. Generated source manifests must name
the actual source and staged SHA-256 for each. Unsupported entry adapters
should fail clearly if accidentally instantiated, and remain nonvisual.
Do not copy the originals over these adapter destinations later in staging.
The custom URI's qmldir must declare `module Caelestia.Services` and register
`singleton SessionManager 1.0 SessionManager.qml`; its QML must have
`pragma Singleton`. Put the staged `imports` directory on the child process's
QML import paths before the built modules.

Qt/QML import closure for this slice:

```text
QtQuick
QtQuick.Layouts
QtQuick.Controls              Interactions' StackView cast
QtQuick.Shapes                StateLayer's original ripple
Quickshell                    ShellScreen, PersistentProperties, ScriptModel,
                              SystemClock, QsWindow, ordinary-window host
Caelestia                     CUtils.clamp in session, optional host helpers
Caelestia.Config              Config, GlobalConfig, Tokens and font builders
Caelestia.I18n                Units for Clock/Time; Tr for Strings
Caelestia.Services            isolated SessionManager adapter only
Caelestia.Blobs               host's original blob surface/deformation machinery
qs.components
qs.components.controls
qs.services
qs.utils
qs.modules.bar
qs.modules.bar.popouts
```

Also preserve Bar's relative imports `"components"` and
`"components/workspaces"` in the staged directory structure. The host/adapter
imports the `qs.modules.drawers` and `qs.modules.session` modules it uses.
The host may add QtQuick.Effects for the original shadow recipe.
Quickshell.Wayland, Quickshell.Hyprland, SystemTray, UPower, Bluetooth, Mpris,
Pipewire, M3Shapes, Caelestia.Models, Images, and Multimedia are **not required
by this reduced closure**.

## Portable plugins and assets

Minimum Caelestia native modules for the initial reduced visuals plus blob surface:
`Caelestia`, `Caelestia.Settings`, `Caelestia.Config`, `Caelestia.I18n`,
`Caelestia.Blobs`. Settings is a dependency of Config
(`plugin/src/Caelestia/Config/CMakeLists.txt:33-40`); I18n depends on Core and
Config (`I18n/CMakeLists.txt:42-59`). Blobs bundles its own shaders
(`Blobs/CMakeLists.txt:1-21`).

No build reduction is needed: use the existing eight-module portable build.
Caelestia.Components, State, and Shaders may remain deployed; the initial slice
does not need their QML types unless the host keeps a prior specimen.
The selected native implementation does require Components through ClipRect.
ScreenState is Quickshell PersistentProperties, **not** Caelestia.State.
Do not enable the upstream Services plugin to obtain SessionManager:
`plugin/src/Caelestia/CMakeLists.txt:32-43` excludes Services/Models/Images/
Multimedia, and `Services/CMakeLists.txt:25-30` links Linux dependencies.

Required copied assets/notices:

```text
LICENSE
assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf
assets/google-sans-flex/LICENSE
```

Load the body font explicitly, as the existing probe does. The original session
and Power icons additionally require **Material Symbols Rounded**, defaulted
in `plugin/src/Caelestia/Config/appearanceconfig.hpp:194-207`. No such font file
was present in the original inspected assets. The parent has now resolved this
with the licensed, pinned font additions described above. An ordinary text font
is insufficient: strings such as `logout`
and `power_settings_new` are font ligatures. Rubik is not needed for these
Clock/session components; it is the dashboard clock/workspace default at
`appearanceconfig.hpp:219-221`.

Set `paths.sessionGif` to `""` for the smallest slice. If retained, stage the
original `assets/kurukuru.gif` and make the Paths adapter resolve `root:/`
into the isolated configuration tree (`userpaths.hpp:22`,
`session/Content.qml:53-68`). The selected no-logo route needs neither
`assets/logo.svg` nor `components/Logo.qml`.

## Service and adapter contracts

| Contract | Minimum behavior and source |
| --- | --- |
| ScreenState | Original `components/ScreenState.qml:3-19`: required ShellScreen `modelData`; mutable booleans `bar`, `osd`, `session`, `launcher`, `dashboard`, `utilities`, `sidebar`; dashboardTab/date. Create one state for the actual host screen and pass the same instance throughout. The initial ordinary-window proposal did not require ShellState; the selected ContentWindow implementation does. |
| Time | Copy original `services/Time.qml:8-30`: enabled, date, hours/minutes/seconds, hourStr/minuteStr/amPmStr, format(fmt), second precision. This is a portable SystemClock, not a process. |
| Colours | `light`, `palette`, `tPalette`; both palette objects need every color used by instantiated originals. Minimum union: m3surfaceContainer, m3onSurface, m3onSurfaceVariant, m3outlineVariant, m3primary, m3secondary, m3tertiary, m3onPrimary, m3onSecondary, m3secondaryContainer, m3onSecondaryContainer, m3error. Host surface may add m3background, m3surface, m3scrim, m3shadow. Sources: Clock:13-77, Power:30, session Content:100-101, IconButton:15-25, ButtonBase:40-41, MaterialIcon:7. |
| SessionManager | Singleton `exec(list<string>): bool`, always consumes and returns **true**, including `[]` and unexpected commands. Expose an explicit unavailable state plus an attempted-action signal/counter for host feedback and verification. Never start a process or perform logout/power actions. Original Content:92-94 falls back to `Quickshell.execDetached(command)` on **any false result**. |
| Audio | `available=false`; no-op/log-only incrementVolume()/decrementVolume(), reached only by Bar.handleWheel (`Bar.qml:88-93`). Keep scrollActions.volume false. |
| Brightness | `available=false`; getMonitorForScreen(screen) returns an inert object with brightness and setBrightness(value), with no read/write/process side effects (`Bar.qml:96-100,146`). A nested Monitor type is unnecessary when disabled ActiveWindow is an adapter with a var monitor. Keep scrollActions.brightness false. |
| Hypr | `available=false`; no-op dispatch; usingLua false; monitorFor(screen) returns a shaped inert monitor if called: lastIpcObject.specialWorkspace.name empty, activeWorkspace.id 1. Bar's wheel code directly dereferences monitor.activeWorkspace at line 86, so returning null is not a defensive contract. Keep scrollActions.workspaces false. |
| Paths | absolutePath(string), returning a safe staged URL for supported `root:/` assets and no user-state paths. With empty sessionGif it is not invoked by the selected content, but provides a clear contract for that static expression. Do not reuse Linux HOME/XDG assumptions from `utils/Paths.qml:11-25`. |
| Popouts.Wrapper | One nonvisual Item type shared by Bar, BarWrapper, Interactions: hasCurrent=false, currentName="", currentCenter, current=null, isDetached=false, detachedMode="", close(). Accept screen/offsetScale if the host sets them. No Content, Nexus, WindowInfo, focus grab, or native windows. |

The previous probe palette (`windows/prototype/services/Colours.qml:9-21`)
is insufficient for Power/session. Extend the isolated adapter with upstream
default values, including m3onPrimary `#541d34`, m3onSecondary `#422932`,
m3secondaryContainer `#5a3f48`, m3onSecondaryContainer `#ffd9e3`, and m3error
`#ffb4ab` (`services/Colours.qml:257-269`).

Disabled entry contracts still need properties set by Bar:

| Staged type | Minimum accepted properties; do not instantiate in this profile |
| --- | --- |
| OsIcon | Item/objectName only (`Bar.qml:125-127`). This is an unavailable entry, not a substitute logo. |
| Workspaces | ShellScreen screen, bool fullscreen (`Bar.qml:133-136`). |
| ActiveWindow | var bar, var monitor (`Bar.qml:143-146`). |
| Tray | bool expanded for closeTray; if fuller defensive API retained: padding, spacing, layout.implicitHeight, items.count/itemAt(), expandIcon Item (`Bar.qml:26-29,55-69`). |
| StatusIcons | items Item if defensive checkPopout support is retained (`Bar.qml:47-53`). |

## Panels and interaction geometry

Original Panels imports and creates every module, regardless of configuration:
OSD, Notifications, Session, Launcher, Dashboard, BarPopouts, Utilities, Toasts,
Sidebar (`modules/drawers/Panels.qml:6-15,52-154`). Thus loading the original
Panels would defeat the minimal slice. The platform Panels adapter must expose
the following members required by the unmodified Interactions:

- Required `screen`, `screenState`, `bar`, `borderThickness`; root fills the
  scene with margins `borderThickness` and left margin `bar.implicitWidth`,
  matching original Panels:19-39.
- `session`: the real original Session.Wrapper, supplied screenState and
  sidebarVisible=false. Keep vertical centering and right anchoring.
- `sessionWrapper`: original Panels' geometry contract, width equal to
  session.implicitWidth * (1-session.offsetScale), centered right,
  height session.implicitHeight. Session's loader determines final height.
  Retain the original arrangement at Panels:77-97 rather than giving the
  session arbitrary host rectangle dimensions.
- `osd` with mutable hovered and offsetScale=1; `osdWrapper`; `sidebar` with
  offsetScale=1; `launcher`, `dashboard`, `utilities` with offsetScale=1;
  `notifications`; `popoutsWrapper`; and the shared `popouts` adapter.
- All unsupported panel geometry Items remain invisible, zero-sized,
  with x/y placed far outside the scene using finite positive values such as
  1000000. `notifications`
  also needs y/height because of the sidebar trigger formula.

Zero size alone is insufficient: `withinPanelHeight/Width` expands the bounds
by Config.border.rounding and top/bottom tests retain
Config.border.minThickness (`Interactions.qml:27-52`). Use off-scene
coordinates for inactive geometry and test edge/corner pointer paths.
Keep popup currentName="" and current=null, so StackView depth checks remain
harmless (`Interactions.qml:82,247`).

Config guards are inconsistent: dashboard and bar hover have options, but OSD
and utilities hover run unconditionally (`Interactions.qml:121-133,234-242`);
sidebar/session drag can write their state without checking enabled
(`Interactions.qml:145-157,175-200`); launcher behavior checks showOnHover
rather than enabled (`Interactions.qml:204-211`). Off-scene geometry reduces
false hits, but right-edge sidebar drag still uses
`min(width-minThickness, barWidth+sidebar.x)`. Therefore raw unsupported state
booleans may be set during a drag. Unavailable adapters must remain closed
regardless of those booleans, with no loaders or actions. Do not assume an
enabled=false config alone makes the entire interaction graph inert.

Preserve Interactions' shortcut state and Connections
(`Interactions.qml:21-25,254-330`), and keep actual content beneath/inside
the original mouse area arrangement so button input can reach child items.
Power click and original session Escape should exercise shared state.
Bar hover requires a profile with persistent=false, showOnHover=true,
screenState.bar=false; persistent=true otherwise obscures the hover test.
Session focus-on-create is at Content:31 and refocus on launcher close at
Content:33-40. The proposed ordinary host would need to implement and verify
outside-click dismissal and focus return independently. The selected native
implementation instead loads ContentWindow's original focus grab; its pointer
and focus acceptance still need their own recorded validation.

## ContentWindow contract and native boundary

`modules/drawers/ContentWindow.qml` is not a drop-in ordinary-window item:

| Source | Dependency/behavior |
| --- | --- |
| :16; `components/containers/StyledWindow.qml:1-15` | StyledWindow derives PanelWindow, attaches WlrLayershell.namespace, assigns transparent color, and propagates Config.screen/Tokens.screen on contentItem. An ordinary host must deliberately supply the attached screen values too; otherwise Config may fall back with warnings (`plugin/src/Caelestia/Config/configattached.cpp:57-65`, tokensattached.cpp:14-19,87-92). |
| :22-35 | ShellState.forScreen(screen), typed HyprlandMonitor, special workspace and fullscreen inspection across monitor/workspace/toplevel objects. |
| :47-59 | dragMaskPadding depends on focusGrab, popout detachment, active workspace toplevel count, and enabled panel drag thresholds. |
| :61-78 | Fullscreen changes close panels. WlrLayershell exclusion/layer/keyboardFocus plus screen-edge anchors affect real desktop behavior. |
| :88-110; `Regions.qml:15-86` | Region union/subtraction/Xor input mask derives from every panel and border. It needs real panel geometry and backend input-region support, not just visible pixels. |
| :112-135 | HyprlandFocusGrab uses launcher/session/sidebar/dashboard/tray-menu state; onCleared closes those states and tray/popouts. This is the native outside-click/focus-dismissal boundary. |
| :137-251 | Scrim, MultiEffect shadow, BlobGroup/BlobInvertedRect and eight PanelBg instances join the border/drawers; also accesses utilities deformation fields. |
| :253-310 | Original Interactions contains Panels and BarWrapper; each panel gets its background deformation matrix. |
| :313-335 | Four ShellState.ComponentRef registrations: rootWindow, interactionWrapper, bar, panels. |
| :337-348 | Inline PanelBg is BlobRect using panel geometry, Tokens.rounding.extraLarge and `(deformAmount * Config.appearance.deformScale)/10000`. |

For an ordinary-host rendering step, retain the original BlobGroup/BlobRect
mechanism and session background recipe (`ContentWindow.qml:191-198`):
deformAmount 0.2; x sessionWrapper.x + session.x + bar.implicitWidth;
implicitWidth session.width; corresponding session Matrix4x4 from
sessionBg.deformMatrix (:279-281). Attribute any copied recipe in the Windows
host. A rectangular placeholder behind session would not establish Caelestia's
original surface/deformation behavior. Extracting the inline PanelBg into a
shared original component is a possible later upstream extension, not work
performed by this audit.

Original Drawers additionally creates an Exclusions object per screen
(`Drawers.qml:15-23`); Exclusions creates four StyledWindows with exclusive
zones (`Exclusions.qml:14-40`). Neither is staged in the selected bounded-native
step. Backend API parity and native behavior are owned by the separate
backend audit.

## Linux processes, files, and startup effects to exclude

| Source | Effect if the original dependency is enabled/referenced |
| --- | --- |
| Root `shell.qml:22-30,45-62` | Forces Notifs, Players, Brightness, Weather.reload and optional VPN; creates Background/Drawers/AreaPicker/Lock and shortcuts, battery/game/idle daemons. Never use it as the isolated entry point. |
| `services/Brightness.qml:76-87,225-236` | Startup `sh -c asdbctl get`, ddcutil detection, per-monitor init invoking asdbctl/ddcutil or `sh` plus brightnessctl. Writes at :213-218 invoke asdbctl/ddcutil/brightnessctl. Must not be copied into this qs.services module. |
| `services/Hypr.qml:112-121,162-165` | Completion installs dynamic Hyprland binds through extras.batchMessage; reads `/usr/share/X11/xkb/rules/base.lst` by default. A matching backend import is not permission to run this service. |
| `services/Audio.qml:6,156-174` | Pipewire import, immediate node refresh, default-device tracking and PwObjectTracker. No audio service initialization is needed for Clock/Power. |
| `services/Nmcli.qml:1429-1453,1701-1705` | Starts network/saved-connection/device queries on completion and persistent `nmcli monitor`; :1697 invokes `nmcli ... list --rescan yes`. |
| `services/Colours.qml:8,82-106,116-136` | Imports Images, changes schemes via `caelestia scheme set`, requests Hypr rules on completion, watches `${Paths.state}/scheme.json`; transparency changes also request rule updates. |
| `services/Wallpapers.qml:33-38,85-118` | Wallpaper CLI setters/previews, current-name FileView, fallback CLI calls on missing/invalid files, Wallpapers model. |
| `services/Notifs.qml:64-85,102-127` | NotificationServer takes notification service role; reads `${Paths.state}/notifs.json`, creates `[]` if absent, later persists notifications. Sidebar activation marks popups false (`NotifDock.qml:26`). |
| `services/Weather.qml:42,348-365,388-408`; `modules/dashboard/WeatherTab.qml:16` | Reload/network/cache behavior and city cache FileView; WeatherTab invokes reload on creation. |
| `utils/SysInfo.qml:49-52,85-123` | Reads `/etc/os-release`, `/proc/sys/kernel/osrelease`, `/proc/sys/kernel/hostname`, `/sys/class/dmi/id/*`, `/proc/uptime`; recurring 15-second uptime reload. Needed by original OsIcon if a logo is enabled. |
| `utils/Paths.qml:11-25` | Assumes HOME/XDG state/cache/config/lib paths and `/usr/lib/caelestia`; not the existing CAELESTIA_* isolated C++ paths. |
| `plugin/src/Caelestia/Services/sessionmanager.cpp:27-60,63-94,96-131` | Constructor connects to system D-Bus/login1 and obtains current session. exec handles login/power commands and aliases loginctl/systemctl; methods perform session/power operations. Not a portable service to instantiate for this probe. |
| `modules/session/Content.qml:91-95`; `Config/sessionconfig.hpp:27-30` | Unknown/unhandled commands fall back to detached execution; defaults are logout/poweroff/hibernate/reboot. Empty command config is defense in depth, not a replacement for a true-returning unavailable adapter. |
| `modules/dashboard/Wrapper.qml:15-28` | File picker plus profile copy to `~/.face` and notify-send. Disabling displayed tabs does not remove this object. |

Config itself reads/watches its isolated `shell.json` and `shell-tokens.json`
and per-monitor layers (`Config/rootnodes.cpp:81-85`,
`Config/common.cpp:11-19`). Set CAELESTIA_CONFIG_DIR before constructing the
engine. Settings mutations can also save these files
(`Settings/rootnode.cpp:7-15,42-43`, `Settings/settingsfile.cpp:191-228`);
do not mutate a real user's Config from the probe. Use existing isolated
state/runtime env and Quickshell DataDir/
StateDir/CacheDir pragmas as in `windows/scripts/Start-Prototype.ps1:18-50`
and Stage-Prototype.ps1:40-45. Do not import the repository service directory
alongside an adapter directory and rely on lazy initialization for safety.

## Initial profile and implementation order

1. Stage only the original set and explicit adapters above. Write a new
   isolated profile before launch, with entries containing only
   spacer/clock/spacer/power (or another explicit spacer order). Do not
   inherit the default enabled entries at `barconfig.hpp:130-141`.
2. Set all `bar.scrollActions` and `bar.popouts` flags false; tray.compact
   false; session.enabled true; all four session.commands values `[]`;
   paths.sessionGif `""`. Disable dashboard, launcher, sidebar, OSD,
   notifications/utilities as their config permits, including launcher/
   sidebar/dashboard showOnHover false. Also disable configuration toasts
   if desired (`Config/rootnodes.cpp:16-28`). Unsupported adapters remain
   unavailable independently of those flags.
3. Supply the complete fixed palette, real fonts and import URI shim. First
   prove the original bar plus session opens, animates, closes, and produces
   no missing-import/type/property warnings in the ordinary host. Log the
   staged originals' hashes separately from adapter hashes.
4. Supply Panels geometry and original Interactions with fullscreen=false.
   Verify Power click, bar hover, session right-edge drag, session Escape,
   button keyboard traversal, and consumed action attempts. Verify attempted
   actions never launch a process, including with a deliberately unexpected
   command passed directly to the adapter.
5. Preserve the original session SDF surface/deformation recipe; exercise
   open and close transitions and inspect screenshots. Separate these visual
   checks from Windows global keyboard focus and real input-mask claims.
6. Add host dismissal/focus return and bounded shutdown checks. Record the
   ordinary host limitation. Native panel/region/focus work must follow the
   backend audit and opt-in authorization; the M1 roadmap still requires
   native/mixed DPI, negative origins, transparency off and lifecycle tests.

There is no `notifs.enabled` property in
`plugin/src/Caelestia/Config/notifsconfig.hpp:11-25`; exclude its service/
wrapper through staging instead of writing an invented config key. Actual
enabled flags exist for dashboard, launcher, sidebar, OSD, and utilities in
their corresponding Config headers. An example isolated `shell.json` is:

```json
{
  "bar": {
    "entries": [
      { "id": "spacer", "enabled": true },
      { "id": "clock", "enabled": true },
      { "id": "spacer", "enabled": true },
      { "id": "power", "enabled": true }
    ],
    "scrollActions": { "workspaces": false, "volume": false, "brightness": false },
    "popouts": { "activeWindow": false, "tray": false, "statusIcons": false },
    "tray": { "compact": false },
    "clock": { "showIcon": false }
  },
  "session": {
    "enabled": true,
    "commands": { "logout": [], "shutdown": [], "hibernate": [], "reboot": [] }
  },
  "paths": { "sessionGif": "" },
  "dashboard": { "enabled": false, "showOnHover": false },
  "launcher": { "enabled": false, "showOnHover": false },
  "sidebar": { "enabled": false, "showOnHover": false },
  "osd": { "enabled": false },
  "utilities": { "enabled": false, "toasts": { "configLoaded": false } }
}
```

The final profile must be read back through the real Config object before
creating Bar, so an ignored/merged entries array cannot accidentally instantiate
an unavailable entry. Keep this bootstrap check in the isolated host/staging
workflow. Set persistent=false separately for the explicit bar-hover scenario.

No upstream extension is required for this adapter-staged slice. If the
project later rejects disabled-entry contract adapters, the smallest useful
upstream change is to separate optional entry implementations into
URL-loaded files, remove the concrete Tray/StatusIcons type references from Bar's casts,
and use an explicit popout interface instead of the full concrete Wrapper.
Merely adding `active: false`, filtering the model, or moving the same named
types into inline Components cannot provide that boundary. A similar optional
panel factory/interface boundary is needed before original Panels can avoid
all unrelated panel imports. Keep that future change localized, preserve
Linux defaults, and review it separately; no originals were edited here.
