# M2 Windows service source audit

Current media follow-up: clean root `d9cdcf9a` and backend `14010429` implement
a default-off Players adapter and original dashboard player details. Native
150%/175% runs observed a healthy backend with no sessions, with read-only
controls and preserved desktop state. Backend PR #3 supplies lifecycle status
and profile-isolated artwork caching.
[Media evidence](../validation/2026-10-25-m2-media/README.md) and the
[revision-specific media audit](M2-MEDIA-BACKEND-GAPS.md) own those claims.
ERM-498 remains In Progress for real-session and transport acceptance.
The baseline inventory below retains its original source revisions.

Static evidence collected 2026-10-25 for ERM-495. Source checkout:
`0e0f9fd61bed186c83626a5aabfcd05c92afb186` (`0e0f9fd6`).
Audited Quickshell gitlink and [source manifest](../sources.lock.json):
`84604c258da92a004b46d62a89718ae615840b98` (`84604c25`).
Original Caelestia baseline: `2e1c51fa76d94457624b642c678218970aa2517a`.

This is a source audit, not a build, runtime, hardware, denial or release test.
No application was launched or desktop state changed by this audit. Source links
are relative to this document; line numbers refer to the revisions above.
Concurrent M2 edits are not evidence for these findings.

Read [AGENTS.md](../../AGENTS.md), [Windows README](../README.md),
[ROADMAP](../ROADMAP.md), [HANDOFF](../HANDOFF.md), and the M1
[dependency](M1-DEPENDENCIES.md) and [backend API](M1-BACKEND-API.md) audits.
M1 established a bounded original bar/session prototype, with unavailable
services. It did not validate Windows services.

Root reports ERM-495 (this audit), ERM-496 (audio integration), and ERM-497
(truthful backend audio capability/errors) in progress. ERM-497 is delegated
separately. The gaps below describe `84604c25`; no later backend fix or pin is
claimed here. Root's selected integration is a separate bounded audio host,
with no unrelated services enabled.

## Complete M2 contract inventory

The service import names often retain Linux terminology while implementing
Windows APIs. Matching names do not establish equivalent behavior.

- **Audio:** `Quickshell.Services.Pipewire` exposes node/link/link-group models,
  default sink/source, writable preferred defaults, and `ready`
  ([pipewire.hpp](../deps/quickshell/src/windows/services/pipewire/pipewire.hpp),
  lines 22-29). Concrete `PwNode` objects have identity, direction/stream flags,
  properties, audio and readiness; audio supports mute, scalar volume and
  channel volumes ([pw_node.hpp](../deps/quickshell/src/windows/services/pipewire/pw_node.hpp),
  lines 27-30, 77-86). Native endpoint/session volume is usable by the original
  Audio contract, subject to the capability/error gaps below. Channel identities
  are `Unknown`; volume is limited to `0..1`, not Linux amplification
  ([pw_node.cpp](../deps/quickshell/src/windows/services/pipewire/pw_node.cpp),
  lines 154-189). `PwObjectTracker` watches object lifetime, rather than enabling
  Linux subscriptions ([pw_object_tracker.cpp](../deps/quickshell/src/windows/services/pipewire/pw_object_tracker.cpp),
  lines 13-31). `Quickshell.Windows.AudioVisualizer` separately exposes
  running/capturing, bars/settings and values, defaulting to stopped; it is not
  the Caelestia CavaProvider/BeatTracker contract
  ([audio_visualizer.hpp](../deps/quickshell/src/windows/system/audio_visualizer.hpp),
  lines 24-32, 93-100).
- **Media:** `Quickshell.Services.Mpris` exposes GSMTC players, metadata,
  transport capabilities, position/length, shuffle and repeat. Raise, quit,
  fullscreen, openUri and player volume have no implementation; stop logs that
  GSMTC has no stop command
  ([player.hpp](../deps/quickshell/src/windows/services/mpris/player.hpp),
  lines 51-90, 112-138;
  [player.cpp](../deps/quickshell/src/windows/services/mpris/player.cpp),
  lines 43-47, 158-161). Original
  [Players.qml](../../services/Players.qml), lines 15-17, 47-65, 94-182,
  also installs shortcuts, exposes IPC and emits toasts. An empty player list
  does not distinguish no sessions from backend initialization failure.
- **Notifications:** `Quickshell.Services.Notifications.NotificationServer`
  preserves tracked notifications and capability flags, adding
  `mirrorSystemNotifications`, access state, mirror activity, `notifySend()` and
  explicit access requests
  ([qml.hpp](../deps/quickshell/src/windows/services/notifications/qml.hpp),
  lines 20-35, 83-85). Mirroring defaults true at line 112. Access can be
  Unknown/Unspecified/Allowed/Denied/Unavailable
  ([toast_mirror.hpp](../deps/quickshell/src/windows/services/notifications/toast_mirror.hpp),
  lines 13-29). Original [Notifs.qml](../../services/Notifs.qml), lines 80-127,
  tracks and persists notifications without exposing those Windows states.
  Mirrored toast actions synthesize app opening, not arbitrary original Windows
  toast actions ([server.cpp](../deps/quickshell/src/windows/services/notifications/server.cpp),
  lines 432-458). `Quickshell.Windows.NotificationSettings` only opens Windows
  settings pages ([notification_settings.hpp](../deps/quickshell/src/windows/system/notification_settings.hpp),
  lines 11-18).
- **Network:** `Quickshell.Windows.Network` provides Internet/Ethernet flags,
  Wi-Fi adapter/radio/scan/connect state, active SSID/BSSID/signal/security,
  location-permission state and network model. Commands cover radio, scan,
  connect, disconnect, forget, list visibility and Windows settings; connection
  completion has a result signal
  ([network.hpp](../deps/quickshell/src/windows/system/network.hpp),
  lines 27-41, 79-86, 121). This is not original
  [Nmcli.qml](../../services/Nmcli.qml), lines 12-45: typed `AccessPoint` and
  `EthernetDevice`, saved-connection details, callback/timer machinery, Ethernet
  control/speed/usage are not supplied by that native interface.
- **Bluetooth:** `Quickshell.Bluetooth` retains default adapter, adapter/device
  models ([bluetooth.hpp](../deps/quickshell/src/windows/bluetooth/bluetooth.hpp),
  lines 69-76), radio/discovery, paired/connected/state/battery and
  pair/connect/disconnect/forget commands
  ([adapter.hpp](../deps/quickshell/src/windows/bluetooth/adapter.hpp),
  lines 41-52; [device.hpp](../deps/quickshell/src/windows/bluetooth/device.hpp),
  lines 40-65). Discoverability has no native setter; pairability/timeouts are
  compatibility state ([adapter.cpp](../deps/quickshell/src/windows/bluetooth/adapter.cpp),
  lines 87-115). Device rename/trusted/blocked/wake setters warn as unsupported
  ([device.cpp](../deps/quickshell/src/windows/bluetooth/device.cpp),
  lines 168-187). Some PIN/passkey pairing kinds require Windows Settings
  ([bt_worker.cpp](../deps/quickshell/src/windows/bluetooth/bt_worker.cpp),
  lines 272-282). Original Bluetooth UI imports this module directly.
- **Power:** `Quickshell.Services.UPower` exposes one aggregate system battery,
  a device model and `onBattery`
  ([core.hpp](../deps/quickshell/src/windows/services/upower/core.hpp),
  lines 19-25). Unknown percentage maps to zero, time-to-full remains zero,
  and capacity/energy/health telemetry is not populated by the status refresh
  ([device.cpp](../deps/quickshell/src/windows/services/upower/device.cpp),
  lines 69-113). PowerProfiles maps Windows overlays; performance availability
  starts true, degradation is None and holds are empty, not discovered Linux
  semantics ([powerprofiles.cpp](../deps/quickshell/src/windows/services/upower/powerprofiles.cpp),
  lines 93-111, 120-155). `Quickshell.Windows.IdlePower` additionally exposes
  idle time and mutable AC/DC screen-off/sleep settings with `lastWriteOk`
  ([idle_power.hpp](../deps/quickshell/src/windows/system/idle_power.hpp),
  lines 16-21, 44-48). Those setters write the power plan, so keep them outside
  a read-only battery slice.
- **Brightness:** `Quickshell.Windows.Brightness` is an asynchronous screen-name
  API: query/probe/refresh/set, method lookup, queried/set-finished/route/system
  change signals ([brightness.hpp](../deps/quickshell/src/windows/system/brightness.hpp),
  lines 43-57). Routes include WMI, LCD, DDC and software gamma. Original
  [Brightness.qml](../../services/Brightness.qml), lines 14-28, 143-236,
  exposes a different typed `Monitor` model and uses Linux commands.
  Hardware-write failure can fall back to gamma and emit success
  ([brightness.cpp](../deps/quickshell/src/windows/system/brightness.cpp),
  lines 1386-1413). Hardware and software control need distinct capability states.
- **App catalog:** Shared `Quickshell.DesktopEntries` supplies applications,
  lookup, typed entries and execute
  ([desktopentry.hpp](../deps/quickshell/src/core/desktopentry.hpp),
  lines 65-100, 121, 316-331). The Windows backend scans AppsFolder, watches
  Start Menu paths and launches through native activation/ShellExecute;
  categories become `PackagedApp`/`Application`
  ([desktopentry_backend.cpp](../deps/quickshell/src/windows/desktopentry_backend.cpp),
  lines 142-158, 244, 277-346). Original launcher
  [Apps.qml](../../modules/launcher/services/Apps.qml), lines 5, 11-20, 65-74,
  also needs excluded Caelestia.Models/AppDb, SQLite state and a Linux terminal
  wrapper. `Quickshell.Windows.AppActions` adds admin/location/settings/uninstall
  commands ([app_actions.hpp](../deps/quickshell/src/windows/system/app_actions.hpp),
  lines 31-35); these are separate explicit actions, not catalog reads.
- **Tray:** `Quickshell.Services.SystemTray` supplies items
  ([qml.hpp](../deps/quickshell/src/windows/services/systray/qml.hpp),
  lines 16-18). Item metadata and activation names match, but `hasMenu=true`
  coexists with `menu=null`, scroll does nothing, and `display()` invokes a
  native context menu while ignoring requested coordinates
  ([item.hpp](../deps/quickshell/src/windows/services/systray/item.hpp),
  lines 64-84, 101-104;
  [item.cpp](../deps/quickshell/src/windows/services/systray/item.cpp),
  lines 197-229). Original [TrayItem.qml](../../modules/bar/components/TrayItem.qml)
  and [TrayMenu.qml](../../modules/bar/popouts/TrayMenu.qml) need native-menu
  adaptation and retain the Images/ColouredIcon dependency.
- **Session:** `Quickshell.Windows.Session` offers secure Windows lock,
  logout/shutdown/reboot, suspend/hibernate, firmware reboot, OS info and
  `canHibernate` ([session.hpp](../deps/quickshell/src/windows/system/session.hpp),
  lines 15-30). It has no upstream SessionManager command parser or
  sleep/lock/unlock signals
  ([sessionmanager.hpp](../../plugin/src/Caelestia/Services/sessionmanager.hpp),
  lines 22-38). Native methods return void; failures are logged. Shutdown/reboot
  adjust the process shutdown privilege and firmware reboot launches shutdown.exe
  ([session.cpp](../deps/quickshell/src/windows/system/session.cpp),
  lines 21-38, 57-109). Original session content falls back to detached execution
  on `exec=false`; retain the consuming
  [unavailable adapter](../shell-prototype/adapters/Caelestia/Services/SessionManager.qml),
  lines 9-14, for ERM-496.

## First slice: Audio contract and original UI boundary

[Audio.qml](../../services/Audio.qml), lines 15-32, exposes previous device
names; typed sinks/sources/streams and default sink/source; output/input
volume/mute; and cava/beatTracker aliases. Lines 34-109 supply output/input
set/increment/decrement, device selection/cycling, stream volume/mute and
stream naming helpers. Preserve those usable names/signatures at the Windows
adapter boundary, with explicit availability. Cava/beat support remains
unavailable, rather than silently being described as implemented.

Specific behavior to preserve or document:

1. Set-volume helpers unmute first; Windows scalar volume stops at 100% even
   if `GlobalConfig.services.maxVolume` is larger. Reject nonfinite values.
2. Node lists refresh immediately and on model changes; defaults must update
   independently of list timing (Audio lines 109-174). Node identity is a
   runtime object/id, not a durable saved device selection.
3. Guard every mutator when disabled/unavailable; validate current list
   membership and sink/source/stream direction. Backend default setters accept
   a node without performing those checks.
4. Original Audio creates device-change toasts, IPC, CavaProvider and BeatTracker
   (lines 130-192). Its C++ visualizers use native Linux PipeWire capture
   ([audiocollector.cpp](../../plugin/src/Caelestia/Services/audiocollector.cpp),
   lines 5, 24-101). A plain QtObject cannot replace every visualizer consumer:
   [ServiceRef](../../plugin/src/Caelestia/Services/serviceref.hpp), line 14,
   requires `Service*`. No visualizer or capture claim belongs to this slice.

Stage the original [AudioPopout.qml](../../modules/bar/popouts/AudioPopout.qml),
with its concrete [PopoutState.qml](../../modules/bar/popouts/PopoutState.qml),
original control dependencies, portable Config/I18n/Components, fixed palette
and process-local fonts. At the audited revision AudioPopout requires PopoutState
at line 16, creates typed PwNode radio delegates at lines 42-75, and binds
volume/wheel/slider at lines 78-102. Its settings button emits
`detachRequested("audio")` at line 114. Handle this locally as unavailable or
through an explicitly selected Windows settings action.

Do not pull in the full original
[popout Wrapper](../../modules/bar/popouts/Wrapper.qml), lines 110-165:
its detached branch creates Nexus; its Content names network, Bluetooth,
battery, keyboard, tray and other panels. Disabled inline components still
require loadable types, as recorded in the M1 dependency audit. Root's separate
bounded audio host is the selected boundary, not a full bar/popout integration.
Keep original Linux defaults intact and describe any localized original UI edit.

## Startup effects, denial and audited backend gaps

- Audio construction creates the native backend immediately
  ([pipewire.cpp](../deps/quickshell/src/windows/services/pipewire/pipewire.cpp),
  lines 17-22). It initializes COM, registers endpoint notifications and reads
  defaults; session/other-device enumeration runs after first frame
  ([pw_backend.cpp](../deps/quickshell/src/windows/services/pipewire/pw_backend.cpp),
  lines 298-338). Session inspection queries process image names at lines
  587-600. This is observation of native state, not an inert fake service.
  Gate construction, not merely the visible UI. Startup must not invoke setters.
- **ERM-497, separately in progress:** at `84604c25`, endpoint volume activation
  can fail while the node still becomes `ready=true` (pw_backend lines 412-427).
  `Pipewire.ready` only establishes backend initialization, not available
  hardware or per-node control. Default selection ignores HRESULTs for Console,
  Multimedia and Communications and updates the default optimistically
  (lines 716-735). Volume/mute errors are logged without QML result signals
  ([pw_node.cpp](../deps/quickshell/src/windows/services/pipewire/pw_node.cpp),
  lines 133-173). An adapter alone cannot truthfully infer denied controls from
  these flags. Bind to the separately reviewed fix when it is pinned; retain
  these findings as historical evidence for this revision.
- Media starts a worker after first frame
  ([gsmtc_backend.cpp](../deps/quickshell/src/windows/services/mpris/gsmtc_backend.cpp),
  lines 19-30). GSMTC access failure logs and returns without a public failure
  state ([gsmtc_worker.cpp](../deps/quickshell/src/windows/services/mpris/gsmtc_worker.cpp),
  lines 93-111). Do not label an empty list as a confirmed healthy service.
- Notification server construction can claim a session-wide mutex/message bus
  for an entry point named `shell.qml`; a competing owner causes a five-second
  claim retry ([server.cpp](../deps/quickshell/src/windows/services/notifications/server.cpp),
  lines 55-91). Mirror access requests are explicit and only request when status
  is Unspecified; while enabled, non-Allowed states start access-status polling
  ([toast_worker.cpp](../deps/quickshell/src/windows/services/notifications/toast_worker.cpp),
  lines 113-147). This is distinct from repeated consent prompts. Dismissal can
  remove the actual Windows notification (lines 272-279); Open can activate or
  launch its app (server lines 355-385). Keep this service unconstructed.
- Network construction starts connectivity and WLAN observation; successful
  WLAN initialization also queries nearby networks. Visible lists trigger scans
  every eight seconds ([network.cpp](../deps/quickshell/src/windows/system/network.cpp),
  lines 15-25, 71-81;
  [network_wifi.cpp](../deps/quickshell/src/windows/system/network_wifi.cpp),
  lines 168-194). Location denial is surfaced for list/current-connection
  queries (network_wifi lines 279-280, 324-325, 369-370). Radio writes can fail
  with only a warning; connection results are richer. Do not change privileges
  or retry denied operations automatically.
- Bluetooth starts a worker after first frame and watches paired devices
  ([bt_backend.cpp](../deps/quickshell/src/windows/bluetooth/bt_backend.cpp),
  lines 24-35; [bt_worker.cpp](../deps/quickshell/src/windows/bluetooth/bt_worker.cpp),
  lines 486-488). Radio access and pairing can be denied or unsupported. Preserve
  null adapter, blocked radio and bounded pending states; avoid automatically
  enabling radio, discovery or pairing.
- UPower registers power notifications and polls every 30 seconds
  ([core.cpp](../deps/quickshell/src/windows/services/upower/core.cpp),
  lines 38-55). PowerProfiles observes effective power mode and writes only on
  explicit profile selection; read/write failures log without a general public
  availability state. No battery and failed battery read must not be presented
  as a real zero-percent battery.
- Brightness probing can reset previous software gamma dimming
  ([brightness.cpp](../deps/quickshell/src/windows/system/brightness.cpp),
  lines 1209-1220). Hardware-write failure automatically tries another route or
  software gamma, then emits success (lines 1386-1413). Denied/unsupported
  hardware must not silently authorize a different display-control method.
- Referencing DesktopEntries starts asynchronous enumeration and path monitoring
  ([desktopentry.cpp](../deps/quickshell/src/core/desktopentry.cpp),
  lines 420-447). SystemTray construction starts native tray hosting by default:
  Explorer snapshots and an interception window are scheduled after first frame
  ([host.cpp](../deps/quickshell/src/windows/services/systray/host.cpp),
  lines 172-201). `QS_WINDOWS_TRAY_HOOK=0` disables interception, not every timer.
  Native menu/activation can foreground another application.
- Backend plugin startup still opts its own process out of power throttling,
  removes stale AppBars, installs animation timing/fonts and the app backend
  ([init.cpp](../deps/quickshell/src/windows/init.cpp), lines 170-180).
  These are existing backend effects, not effects introduced by audio.
  Do not instantiate Taskbar/Tiling or claim zero global bookkeeping; see the
  M1 backend audit for native panel/focus and virtual-desktop effects.

## Linux process and filesystem audit

Read-only `rg -n` searches used these patterns against the concrete sources
below, plus header/property and startup-path inspection:

```powershell
rg -n 'execDetached|\bProcess\s*\{|command\s*:|\.exec\(' services/Audio.qml services/Players.qml services/Notifs.qml services/NotifData.qml services/Brightness.qml services/Nmcli.qml modules/launcher/services/Apps.qml modules/session/Content.qml modules/dashboard/Wrapper.qml
rg -n 'HOME|XDG|/usr/|/etc/|/proc/|/sys/|Paths\.(state|cache|config|notifimagecache)|apps\.sqlite|notifs\.json|\.face' utils/Paths.qml utils/SysInfo.qml services/NotifData.qml services/Notifs.qml services/Brightness.qml services/Nmcli.qml modules/launcher/services/Apps.qml modules/dashboard/Wrapper.qml services/Hypr.qml
rg -n 'systemBus|org\.freedesktop|loginctl|systemctl|QProcess|/proc/|/sys/' plugin/src/Caelestia/Services/sessionmanager.cpp plugin/src/Caelestia/Services/audiocollector.cpp plugin/src/Caelestia/Models/appdb.cpp
rg -n 'execDetached|command:|exec\(|/usr/|/sys/|/proc/|XDG|HOME|FileView|path:' services/Colours.qml services/Wallpapers.qml services/Recorder.qml modules/launcher/services/Actions.qml modules/launcher/services/Schemes.qml modules/launcher/services/M3Variants.qml
```

Findings, not an assertion that every Linux dependency in the repository is
enumerated:

- [Brightness.qml](../../services/Brightness.qml), lines 76-87, 214-236:
  startup `sh -c asdbctl get`, ddcutil detection and per-monitor initialization;
  writes invoke asdbctl/ddcutil/brightnessctl.
- [Nmcli.qml](../../services/Nmcli.qml), lines 190-205, 273, 1294-1306,
  1429-1453, 1694-1705: nmcli queries, startup refresh/monitor and explicit
  rescan; `sh` reads `/sys/class/net` device/speed/byte-counter files.
- [SessionManager](../../plugin/src/Caelestia/Services/sessionmanager.cpp),
  lines 27-60, 78-82, 134: system D-Bus/login1 and loginctl/systemctl aliases.
  [Session Content](../../modules/session/Content.qml), lines 92-94, and
  [launcher Actions](../../modules/launcher/services/Actions.qml), lines 53-54,
  fall back to arbitrary detached commands when the manager declines one.
- [Paths.qml](../../utils/Paths.qml), lines 11-24: HOME/XDG directories and
  `/usr/lib/caelestia`; these QML paths do not automatically use the portable
  C++ `CAELESTIA_CONFIG_DIR`/state/runtime isolation.
  [SysInfo.qml](../../utils/SysInfo.qml), lines 49-52, 85-123: Linux
  `/etc`, `/proc`, `/sys` files and recurring uptime reads.
- [Notifs.qml](../../services/Notifs.qml), lines 64-77, 102-127:
  `${Paths.state}/notifs.json`, creating it when absent.
  [NotifData.qml](../../services/NotifData.qml), lines 76-120: image-cache
  writes through a hidden native window. [Apps.qml](../../modules/launcher/services/Apps.qml),
  lines 11-20, 68-73: frequency database writes at `${Paths.state}/apps.sqlite`
  and `assets/wrap_term_launch.sh` for terminal apps.
- Broader UI graph: [dashboard Wrapper](../../modules/dashboard/Wrapper.qml),
  lines 15-27, copies a profile image to `~/.face` and runs notify-send.
  [Hypr.qml](../../services/Hypr.qml), lines 112-121, 162-165, installs
  compositor bindings and reads XKB rules.
  [Colours.qml](../../services/Colours.qml), lines 82-106, 116-136, runs
  `caelestia scheme`, reads scheme state and updates Hypr rules.
  [Wallpapers.qml](../../services/Wallpapers.qml), lines 33-38, 85-117,
  invokes the wallpaper CLI including missing-state fallback.
  [Schemes.qml](../../modules/launcher/services/Schemes.qml), lines 43-85,
  and [M3Variants.qml](../../modules/launcher/services/M3Variants.qml), line 83,
  use the scheme CLI. [Recorder.qml](../../services/Recorder.qml), lines 50-62,
  runs pidof/gpu-screen-recorder checks and `caelestia record`.

These findings justify explicit source staging. Hiding a component does not
remove its static imports or startup objects. Do not stage upstream
[shell.qml](../../shell.qml), lines 22-30, 44-63: it eagerly references services
and creates background, lock, drawers and daemons.

## Staged sequence and active issue acceptance

1. **ERM-495, audit:** retain this revision-specific inventory, original UI
   boundaries, process/path findings, denial limits and remaining ticket
   candidates. Completion of the audit is not completion of M2.
2. **ERM-497, separate backend work:** establish truthful per-node control
   capability and observable mutation errors, including default routing.
   Failed activation must not imply a writable ready node; failed writes must
   not publish optimistic success. Check all three default roles and define
   partial failure. Exercise failures deterministically, with bounded cleanup
   and no permission/privilege workaround. Review and commit backend changes in
   its fork before updating gitlink and manifest together. A new pin needs its
   own evidence; this document does not certify it.
3. **ERM-496, bounded audio host:** stage one Windows Audio adapter, original
   AudioPopout/PopoutState and its explicit control closure. Keep fixed theme
   and isolated config/state/runtime/data/cache, without importing all services.
   Enable no media, notifications, network, Bluetooth, brightness, app catalog,
   tray, session actions, global shortcuts, toasts or visualizers.
4. Prove disabled mode and fixture states first. Then run explicitly opted-in
   native observation. Enable real writes only through deliberate user actions
   in the integration profile, with separately recorded mutation validation.

ERM-496 acceptance criteria:

- Default-off mode does not construct Pipewire or issue audio writes. The
  opt-in host clearly identifies native observation/control state.
- Preserve the core Audio property/method names above; expose explicit disabled,
  initializing, no-output, no-input and unsupported/denied-control states where
  the reviewed backend can distinguish them. Do not infer permission from the
  audited pin's `ready` alone.
- Original AudioPopout and controls load/render without missing imports,
  properties, signals or binding warnings. Settings detachment stays bounded.
  Record source/staged hashes and any localized original UI adaptation.
- Fixture checks cover list/default timing, hot removal, null/stale/wrong-kind
  nodes, finite/range guards, failed mutations and denied/unavailable controls.
  Backend-originated state changes do not trigger setters or feedback loops.
  Tests of fake objects do not establish concrete PwNode/native compatibility.
- Native evidence records source/backend/runtime/toolchain revisions, command,
  opt-in mode, diagnostics and observed device/default/volume synchronization.
  Record unavailable hardware scenarios as untested unless actually exercised.
  Volume changes document original unmute behavior and routing changes document
  all affected Windows default roles.
- Startup/shutdown preserves existing application sessions, taskbar/work areas,
  tiler, autostart and ordinary configuration; account for existing backend
  bookkeeping. Bound shutdown and clean up only the test-owned host.
  Keep the previous M1 gate intact.
- If pins or setup instructions change, run the required
  `Test-Environment.ps1 -Json` report. Record it as prerequisites, separately
  from successful build/runtime evidence.

## Candidate remaining M2 tickets

Do not recreate ERM-495, ERM-496 or ERM-497. These are uncreated candidates for
root to deduplicate against Linear, each enabled and validated independently:

1. **Windows service path boundary:** isolated/native QML Paths adapter plus
   safe Windows SysInfo data. Acceptance: no HOME/XDG/Linux-file fallback,
   writes confined to the selected profile, and original Linux behavior retained.
2. **GSMTC Players integration:** preserve player selection/metadata and original
   transport UI; capability-gate unsupported actions and distinguish absent
   sessions from unavailable backend where possible. Acceptance: no automatic
   playback, shortcuts, toasts or capture; session arrival/removal and denied
   startup have recorded outcomes.
3. **Read-only power status:** original battery status/popout with truthful
   absent/unknown telemetry. Acceptance: desktop-without-battery and battery
   states handled; no profile or idle-plan writes. Profile selection and
   IdlePower settings remain a separate later issue if desired.
   **Progress:** implemented as ERM-499's bounded slice on
   `windows/m2-battery-service`: a pure QtObject
   [UPower adapter](../services/battery/BatteryService.qml) with no mutating
   methods, the original status/popout components with
   `profileStatusEnabled`/`profileControlsEnabled` hooks that keep
   PowerProfiles unreferenced and the overlay-scheme write path unreachable,
   and a host that instantiates the original components only after the
   read-only opt-in (they bind `UPower` directly). The localized edits to
   [BatteryStatus.qml](../../modules/bar/components/status/BatteryStatus.qml)
   and [Battery.qml](../../modules/bar/popouts/Battery.qml) add only those
   hooks and their false-state rendering; upstream defaults are preserved.
   [Acceptance evidence](../validation/2026-10-25-m2-battery/README.md) covers
   the batteryless desktop path natively at clean `41cf6aae`; battery-present
   behavior is fixture-validated only, and IdlePower/profile selection stays
   out of scope.
4. **Windows Network adapter and original network UI:** define explicit
   AccessPoint/Ethernet boundaries instead of porting the nmcli process graph.
   Acceptance: absent adapter/location denial, bounded list-visible scans,
   action results, no credential logging and no privilege changes. Keep advanced
   Ethernet configuration outside the first network issue.
   **Progress:** implemented as ERM-500's bounded slice on
   `t3/network-service-ui` at clean `475c7a27` with backend `14010429`.
   A Quickshell-free [NetworkService](../services/network/NetworkService.qml)
   exposes disabled/initializing/no-adapter/location-denied/radio-off/
   connecting/connected/disconnected states and hides lists when a WLAN query
   cannot be truthful. [Nmcli.qml](../services/network/Nmcli.qml) is staged in
   place of the upstream singleton and owns the typed `AccessPoint`/
   `EthernetDevice` boundary; the original
   [Network.qml](../../modules/bar/popouts/Network.qml) popout gained
   upstream-preserving control/connect/status hooks. Scans are bounded to a
   visible list, connect results come only from `wifiConnectResult`, and radio/
   disconnect/forget stay requested/unverified because the backend has no
   result. There is no password path; secure networks without a saved profile
   point to Windows Settings. The pinned backend has no initialization/error
   state (a WLAN failure looks like no adapter), performs one startup query
   even while hidden, and trusts `connectToNetwork()` input; the adapter guards
   membership and credentials. Ethernet remains a connected flag with no
   control, speed or usage. [Evidence](../validation/2026-10-25-m2-network/README.md)
   records 329 fixture assertions, native Disabled/ReadOnly smoke at 150%/175%
   with 0 commands and 0 scans, the M1 regression and media/battery fixtures.
   Interactive control, real access-point connect/forget, radio toggling and
   location denial/recovery remain untested.
5. **Bluetooth original status/popout integration:** preserve typed backend
   devices and unsupported-control states. Acceptance: null/blocked adapter,
   discovery lifecycle and denied pairing settle; unsupported pairing delegates
   to Windows Settings without implementing credential UI or repeated prompts.
   **Progress:** implemented as ERM-501's bounded slice on
   `t3/bluetooth-service-integration` (`ddba8d12`): a pure QtObject
   [BluetoothService adapter](../services/bluetooth/BluetoothService.qml) with
   explicit disabled/initializing/null-adapter/blocked/off/unknown states,
   bounded discovery and connect/pair settling, and refusing unsupported
   setters; the original status/popout components are instantiated only after
   opt-in. The localized edits to
   [Bluetooth.qml](../../modules/bar/popouts/Bluetooth.qml) add only
   `controlsEnabled`, `settingsDelegatesToWindows` (explicit
   `ms-settings:bluetooth`) and `settlingTimedOut` hooks; upstream defaults are
   preserved. [Acceptance evidence](../validation/2026-10-25-m2-bluetooth/README.md)
   covers 182 adapter assertions and native disabled/read-only runs at
   150%/175% on a real Intel adapter with zero paired devices; interactive
   controls, null/blocked/off hardware, paired devices, discovery and
   PIN/passkey delegation remain untested.
6. **Notification local delivery boundary:** isolate history/image-cache paths,
   disable system mirroring initially and account for session-bus ownership.
   Acceptance: fixture/local notifications, persistence and competing-owner
   behavior work without claiming or dismissing real system notifications
   unexpectedly. **System notification mirroring** should be a dependent
   separate issue covering explicit consent, denied polling, app-open and
   Windows dismissal semantics.
7. **Brightness route policy:** adapt per-screen Monitor contract with explicit
   hardware versus software capability. Acceptance: absent/denied/DDC failures
   cause no automatic gamma write; querying and teardown side effects are
   understood. Implement/review any backend policy gap before live writes.
8. **Read-only app catalog and search:** adapt AppDb/path/terminal boundaries
   around DesktopEntries. Acceptance: original search handles empty/failed scan,
   names/icons and profile-local frequency state; enumeration never launches.
   Explicit app launch is separately tested; admin/uninstall actions stay out.
   **Progress:** implemented as ERM-505's bounded slice on
   `t3/windows-app-catalog-search` (topic worktree). A pure
   [AppsService](../services/apps/AppsService.qml) imports no Quickshell and
   separates disabled/scanning/empty/failed/ready states, the preserved
   `search`/`query`/`list`/prefix contract (upstream fzf/fuzzysort), the original
   favourite/frequency/name order and the launch policy. A thin
   [NativeAppCatalog](../services/apps/NativeAppCatalog.qml) wraps
   `DesktopEntries`; [AppFrequencyStore](../services/apps/AppFrequencyStore.qml)
   replaces the excluded AppDb with atomic profile-local JSON
   (`$CAELESTIA_STATE_DIR/apps-frequencies.json`, no SQLite/HOME/XDG) and
   tolerates missing/corrupt documents. `CAELESTIA_WINDOWS_APPS=1` observes and
   searches only; `CAELESTIA_WINDOWS_APP_LAUNCH=1` is a separate opt-in.
   Terminal entries are an explicit unsupported launch instead of the missing
   Linux terminal wrapper. The localized edit to
   [AppList.qml](../../modules/launcher/AppList.qml) adds only `appsOnly`
   (default false) and keeps upstream Linux behavior. A bounded host stages the
   original list/search components; 173 offscreen assertions plus native
   disabled/read-only smoke at 150%/175% cover the fixture and empty/ready paths
   ([evidence](../validation/2026-10-25-m2-apps/README.md)). The backend exposes
   no scan result or per-command outcome
   ([gaps](M2-APPS-BACKEND-GAPS.md)), so native scan failure reads as `empty`,
   and no native launch was performed. Real activation, Interactive mode and
   terminal launch remain untested.
9. **Native tray boundary:** define native context-menu behavior and review
   interception ownership before enabling it. Acceptance: null semantic menus,
   Explorer restart, stale owners, activation and shutdown are handled; no
   taskbar setting changes or competing tray takeover.
10. **Explicit Windows session actions:** retain unavailable behavior by default;
    map only allowlisted actions and expose capability/results. Acceptance:
    unknown commands are consumed without detached fallback, secure Windows lock
    is used, and unsupported sleep/hibernate/privilege-denied actions fail
    clearly. Destructive actions require a separately agreed live test.
    **Progress:** implemented as ERM-507's bounded slice on
    `t3/windows-session-actions`: a pure
    [SessionService](../services/session/SessionService.qml) with an explicit
    allowlist (secure lock, logout, shutdown/poweroff, reboot, suspend,
    capability-gated hibernate, firmware reboot), `requested`-not-`succeeded`
    results, and consumed-unsupported outcomes for arbitrary/unknown commands.
    The [native facade](../services/session/NativeSessionBackend.qml) is loaded
    only after `CAELESTIA_WINDOWS_SESSION=1`; dispatch additionally requires
    `CAELESTIA_WINDOWS_SESSION_ACTIONS=1`. The localized
    [session](../../modules/session/Content.qml) and
    [launcher](../../modules/launcher/services/Actions.qml) hooks preserve Linux
    fallback behavior and block detached execution in the Windows adapter.
    Destructive actions stay behind an explicit confirmation gate; the original
    UI has no confirmation flow at this revision, so they remain disabled
    instead of being auto-confirmed. The backend methods return void and only log
    failures (`windows/deps/quickshell/src/windows/system/session.cpp:45-115`).
    Native Disabled/Observe smoke never invokes an action; no real session action
    was executed. [Evidence](../validation/2026-10-25-m2-session/README.md)
    covers fixtures, two native modes and shared regressions. Real
    privilege-denied behavior and destructive live acceptance remain untested.
