# Idle work inventory

Part of [#35](https://github.com/KldsSeeGhosts/caelestia-windows/issues/35). This page lists the shell's
idle-time work as read from source. It records no measurement and claims no gain. The measurement suite is
the companion work in [#26](https://github.com/KldsSeeGhosts/caelestia-windows/issues/26).

Idle here means every drawer closed, nothing recording, no media playing, the seeded
[`windows/shell/shell.json`](../../shell/shell.json) defaults, and the optional integrations (Wallpaper
Engine, notification mirroring, CPA quota) that those defaults leave off or unconfigured.

## Method

- The staged tree is the set of values in [`windows/shell/sources.json`](../../shell/sources.json), not the
  upstream directory layout. The map stages 347 QML files, 177 of them from `windows/`. 108 of the 278
  upstream QML files under `components/`, `modules/`, `services/`, `utils/` and `daemons/` are not in the
  map and never run on Windows.
- Where the map replaces a path, the adapter is the file that runs, so the adapter is the file read here.
  The staged path is in the same row as the source path.
- `windows/services/` is staged almost completely. The only files there that the map omits are service
  test fixtures and READMEs.
- Paths are repository paths, the files a change would edit. Line numbers are from those files. Staging
  prepends three pragma lines and one `WindowsFonts` line to `shell.qml`, so a staged line number there is
  four higher than the number shown.
- `wakeups/min` is 60000 divided by the interval. It counts timer expiries, not cost. The cost column is a
  rough description of the work each expiry triggers.
- A QML `Timer` with no `running` binding is idle until something calls `start()`. Those are listed with
  the condition that starts them.

## 1. Repeated QML timers in the staged tree

Idle rows first, then rows that only run while a panel, a capture or a recording is open. "Idle" means the
timer is running with no drawer open.

| Source | Staged as | Interval | Idle | Work per expiry |
| --- | --- | --- | --- | --- |
| `windows/shell/adapters/services/Time.qml:53` | `services/Time.qml` | 1000 ms | yes | No QML `Timer`: the `SystemClock` element at this line ticks. `sample()` runs a locale format, sets six properties and re-splits `timeStr`. About ten bar bindings re-evaluate. |
| `windows/shell/adapters/services/Recorder.qml:351` | `services/Recorder.qml` | 15000 ms idle, 5000 failed, 1000 active | yes | Starts `recorder --status` as a child process and parses its reply. |
| `windows/shell/adapters/services/Recorder.qml:360` | `services/Recorder.qml` | 30000 ms | yes, when no recorder exists | Native path probe through `Glazier.refresh()`. No process. |
| `windows/quota/services/Quota.qml:1279` | `services/Quota.qml` | 60000 ms | only when `cpa-agents.json` exists and the panel is enabled | HTTP summary and analytics refresh, then a cache file write. |
| `services/Weather.qml:394` | same | 3600000 ms | yes, once the dashboard has opened | HTTPS forecast fetch and JSON parse. |
| `windows/services/wallpaperengine/WallpaperEngine.qml:520` | `services/WallpaperEngine.qml` | 15000 ms running, 60000 ms otherwise | only when Wallpaper Engine is enabled or observed running | Python bridge status scan. |
| `windows/services/wallpaperengine/WallpaperEngine.qml:528` | `services/WallpaperEngine.qml` | 10000 ms | only during a scan | Scan watchdog. Stops a hung bridge. |
| `windows/shell/adapters/imports/Caelestia/Services/NetworkUsage.qml:41` | `imports/Caelestia/Services/NetworkUsage.qml` | 2000 ms | no, dashboard open | Appends download and upload samples to ring buffers. |
| `modules/dashboard/dash/Media.qml:34` | same | `dashboard.mediaUpdateInterval`, 500 ms | no, media playing | Position poll for the media progress bar. |
| `modules/dashboard/media/Details.qml:38` | same | `dashboard.mediaUpdateInterval`, 500 ms | no, media playing | Same position poll for the expanded player. |
| `windows/quota/services/Quota.qml:1287` | `services/Quota.qml` | 10000 ms | no, quota drawer open | Updates `nowMs` for reset countdowns. |
| `components/controls/TextFieldBase.qml:65` | same | 500 ms | no, text field focused | Toggles caret opacity. |
| `components/controls/LoadingIndicator.qml:79` | same | 650 ms | no, while loading | Advances the shape morph animation. |
| `modules/bar/popouts/WirelessPassword.qml:211` | same | 50 ms | no, popout open without an SSID | Retries reading the network from the service, up to 20 times. |
| `modules/bar/popouts/WirelessPassword.qml:559` | same | 1000 ms | no, while connecting | Calls `checkConnectionStatus()`. |
| `windows/shell/adapters/services/CaptureUi.qml:99` | `services/CaptureUi.qml` | 16 ms | no, capture pending | Polls until Glazier hides itself, then opens the picker. |
| `windows/shell/adapters/modules/areapicker/ThumbnailCard.qml:165` | `modules/areapicker/ThumbnailCard.qml` | 50 ms | no, recording overlay shown | Countdown ticker. |
| `windows/shell/adapters/modules/areapicker/Thumbnails.qml:465` | `modules/areapicker/Thumbnails.qml` | `dragSweepInterval` | no, picker open | Sweeps closed drag files. |
| `windows/shell/adapters/modules/areapicker/Thumbnails.qml:474` | `modules/areapicker/Thumbnails.qml` | `retryInterval` | no, picker open | Retries pending temporary files. |
| `windows/quota/modules/quota/QuotaPopover.qml:87` | `modules/quota/QuotaPopover.qml` | `revealDelay` | no, hover | Delays reveal. |
| `windows/quota/modules/quota/QuotaPopover.qml:92` | `modules/quota/QuotaPopover.qml` | `hideGrace` | no, hover | Delays dismiss. |
| `windows/shell/shell.qml:410` | `shell.qml` | 3000 ms, 15000 ms in CI | only under `-Smoke` | Drives the smoke panel schedule and exits. |
| `modules/sidebar/NotifDock.qml:194` | same | 15 to 80 ms | no, after a clear click | Closes notifications group by group. Stops when empty. |
| `modules/sidebar/NotifDockList.qml:101` | same | 15 ms | no, after a group clear click | Closes up to 30 notifications per tick. Stops when empty. |

Other timers, all short-lived or input-driven: `windows/quota/services/Quota.qml:286` (spawn failure
check), `:864` (request watchdog), `:1251` (hub refresh), `windows/shell/adapters/services/Recorder.qml:367`
(process timeout), `:377` (start timeout), `windows/shell/adapters/services/SchemeGenerator.qml:292`
(helper timeout, only with a request in flight), `windows/shell/adapters/services/WallpaperFolderService.qml:556`
and `:565` (job watchdog and exit grace), `windows/shell/adapters/services/Wallpapers.qml:666` (source
record retry), `windows/shell/adapters/services/Glazier.qml:292` and `:311` (start attempt and hidden
timeout), `windows/shell/adapters/modules/areapicker/AreaPicker.qml:261` (save timeout),
`windows/shell/adapters/modules/areapicker/EditorState.qml:154` (clear-armed reset),
`windows/services/clipboard/ClipboardOverlay.qml:279` (80 ms focus after open),
`windows/services/wallpaperengine/WallpaperEngine.qml:511` (300 ms config debounce),
`modules/notifications/Notification.qml:627` and `modules/sidebar/NotifActionList.qml:132` (3 s copy
feedback), `modules/osd/Wrapper.qml:87` (OSD hide delay), `components/controls/FilledSlider.qml:113`,
`components/controls/StyledScrollBar.qml:113`, `components/controls/StyledSpinBox.qml:131` (press repeat),
`components/controls/TextFieldBase.qml:58` (blink re-enable), `components/containers/StyledFlickable.qml:26`
and `components/containers/StyledListView.qml:26` (end a simulated flick), `services/Weather.qml:401`, `:418`
and `:430` (retry and save), `modules/bar/popouts/WirelessPassword.qml:119`, `:331` and `:580` (focus,
password focus, connection confirmation).

## 2. Processes, detached commands and file watchers

| Source | What it starts | While idle |
| --- | --- | --- |
| `windows/shell/adapters/services/Recorder.qml:336` | `recorder --status`, every 15 s | yes, one process creation per poll |
| `windows/shell/adapters/services/SchemeGenerator.qml:248` | Python `serve` helper, stdin driven, stays warm | no expiry, blocks on stdin |
| `windows/services/notifications/Notifs.qml:388` | `powershell.exe Banner-Suppression.ps1 -Command Worker`, stdin driven | no expiry, blocks on `Console.In.ReadLine()` |
| `windows/quota/services/Quota.qml:305` | Python keepalive helper | no, only after an explicit Keepalive click |
| `windows/services/wallpaperengine/WallpaperEngine.qml:543` and `:589` | Python bridge scan and action | only with the integration enabled |
| `windows/shell/adapters/services/WallpaperFolderService.qml:523` | Python folder job | no, picker only |
| `windows/shell/adapters/modules/nexus/pages/UpdatesPage.qml:177`, `:200`, `:208` | PowerShell update queries | no, page open only |
| `windows/shell/adapters/services/UpdateManager.qml:61` | PowerShell update actions | no, user action |
| `windows/services/session/NativeSessionBackend.qml:126` | Session switch helper | no, user action |
| `windows/shell/adapters/modules/launcher/services/Actions.qml:79` | `Quickshell.execDetached` for launcher actions | no, user action |
| `windows/shell/adapters/modules/launcher/items/CalcItem.qml:91` | `calc.exe` | no, user action |
| `windows/shell/adapters/modules/session/Content.qml:300` | `Quickshell.execDetached` for session actions | no, user action |
| `modules/utilities/cards/RecordingList.qml:116` and `:130` | Play or reveal a recording | no, user action |

`FileView watchChanges: true` uses an OS file watcher, not a poll. Each one holds a handle and produces no
wakeup until the file changes. Active watchers: `windows/quota/services/Quota.qml:361` and
`windows/quota/services/QuotaConfig.qml:76`, `:88` (CPA config and quota settings),
`windows/services/notifications/Notifs.qml:345` (`windows.json` banner settings),
`windows/services/wallpaperengine/WallpaperEngine.qml:367`, `:480` (Wallpaper Engine config and
scene files), `windows/shell/adapters/services/Colours.qml:112` (`scheme.json`),
`windows/shell/adapters/services/Glazier.qml:302` (Glazier lifecycle), `windows/shell/adapters/services/UpdateManager.qml:83`
(update state), `windows/shell/adapters/services/Wallpapers.qml:586`, `:597` (wallpaper folders).

`watchChanges: false` file views are one read. They are listed for completeness:
`windows/quota/services/Quota.qml:378`, `windows/services/apps/FileAppFrequencyStore.qml:26`,
`windows/services/wallpaperengine/WallpaperEngine.qml:453`, `windows/shell/adapters/services/WallpaperProvenance.qml:44`,
`windows/shell/adapters/services/Wallpapers.qml:616`, `:654`.

## 3. Models rebuilt on a timer

Only three places rebuild observable collections from a timer, and none of them while idle:

- `windows/quota/services/Quota.qml:1279` replaces the provider and account lists every 60 s when the
  integration is configured. The drawer delegates rebuild on the next open.
- `windows/shell/adapters/imports/Caelestia/Services/NetworkUsage.qml:41` pushes into the sparkline buffers
  every 2 s while the dashboard is open.
- `services/Weather.qml:394` replaces the forecast array every hour.

`Repeater` and `ListView` delegates elsewhere rebuild on property changes, not on timers. The two `clearTimer`
loops (`modules/sidebar/NotifDock.qml:194`, `modules/sidebar/NotifDockList.qml:101`) mutate the notification
model repeatedly for under a second after a user click.

## 4. Native polling in the shell plugin

The plugin adds no periodic idle work. Its timers are debounces, deadlines and animations:

| Source | Kind |
| --- | --- |
| `plugin/src/Caelestia/Models/appdb.cpp:118` | 300 ms single-shot debounce on `setEntries`. No filesystem watcher. |
| `plugin/src/Caelestia/Settings/settingsfile.cpp:54`, `:60`, `:51` | 500 ms save debounce, 50 ms load debounce, save retry. All driven by watcher events. |
| `plugin/src/Caelestia/Windows/Clipboard/windowsclipboard.cpp:115`, `:372`, `:387` | Paste injection and modifier retry, paste only. |
| `plugin/src/Caelestia/Windows/Clipboard/windowsclipboardworker.cpp:541` | 150 ms clipboard event coalescing. The worker is driven by a clipboard listener. |
| `plugin/src/Caelestia/Windows/capturehost.cpp:152`, `:221`, `:441` | Capture deadlines and recovery. |
| `plugin/src/Caelestia/Components/lazylistview.cpp:507`, `:640`, `:1137` | Item readiness and removal delays. |
| `plugin/src/Caelestia/Components/animatedrepeater.cpp:325`, `:379` | Removal and settle delays. |
| `plugin/src/Caelestia/Windows/windowsfocusguard.cpp:209`, `:256` | Queued focus repair. |
| `plugin/src/Caelestia/toaster.cpp:19` | Toast close timeout. |

Two sleeps exist and both are bounded work, not idle loops: `windowsclipboardworker.cpp:187` polls a
WinRT clipboard read every 10 ms until it completes or times out, and the plugin's worker threads block on
their own queues.

`plugin/src/Caelestia/Services/` is not built on Windows. `CMakeLists.txt` adds it only when
`CAELESTIA_PORTABLE_UI` is off, so `TickingService` and the pipewire, DBus and sensor services never load.

## 5. Native polling in the backend (read-only, separate repository)

These are backend follow-ups. None is changed by this document, and each needs a paired backend revision and
its own measurement before a shell commit could rely on it.

| Source (backend submodule) | Interval | Idle | Work per expiry |
| --- | --- | --- | --- |
| `windows/deps/quickshell/src/windows/system/keyboard.cpp:183`, `:201` | 500 ms | yes | `installedLayouts()` plus compare, then a QML signal on change. The comment at `:194` records this as a deliberate compatibility fallback. |
| `windows/deps/quickshell/src/windows/window_tracker.cpp:520`, `:527` | 10000 ms | yes | `IsWindow` for every tracked window in `sweepDestroyed()` at `:797`. |
| `windows/deps/quickshell/src/windows/services/upower/core.cpp:53` | 30000 ms | yes | `GetSystemPowerStatus` through `updateFromSystemPowerStatus()` at `:68`. Three power-setting notifications already call `refresh()`. |
| `windows/deps/quickshell/src/windows/services/upower/powerprofiles.cpp:167` | 10000 ms | yes | Reads the active power scheme. Default interval at `powerprofiles.hpp:128`. |
| `windows/deps/quickshell/src/windows/bluetooth/bt_worker.cpp:328` | 60000 ms | while a Bluetooth service exists | Reads battery level for paired devices. `BATTERY_POLL_MS` at `:101`. |
| `windows/deps/quickshell/src/windows/input_mask.cpp:201` | 10000 ms | yes | Exchanges three atomics, normally returns immediately. Late input diagnostic only. |
| `windows/deps/quickshell/src/windows/input_mask.cpp:189` | 16 ms | only when the mouse hook failed and a mask or cursor watcher needs it | Fallback path at `:452`. Not used when the hook starts. |
| `windows/deps/quickshell/src/windows/services/notifications/toast_worker.cpp:310` | 10000 ms, 2000 ms active | only when access observation is opted in | WinRT access status read. `mObserve` is off until the service opts in. |
| `windows/deps/quickshell/src/windows/services/notifications/toast_worker.cpp:98` | 2000 ms | only when mirroring is enabled and the change listener is unavailable | Toast resync. |
| `windows/deps/quickshell/src/windows/services/systray/host.cpp:214` | 1500 ms | only with `QS_WINDOWS_TRAY_HOOK=brief` | Tray snapshot. |
| `windows/deps/quickshell/src/windows/taskbar.cpp:516`, `:526` | 250 ms revealed, 2000 ms concealed | only with `hideTaskbar` | Reconciles taskbar visibility. |
| `windows/deps/quickshell/src/windows/hotkeys.cpp:554` | 15 ms | only while a chord is held | `pollReleases()`. |
| `windows/deps/quickshell/src/windows/system/network.cpp:26` | 8000 ms | only while the Wi-Fi list is visible | WLAN scan. Started at `:175`. |
| `windows/deps/quickshell/src/windows/services/pipewire/pw_peak.cpp:15` | 33 ms | only while a peak monitor is enabled | COM peak read. Started at `:52`. |
| `windows/deps/quickshell/src/windows/system/system_stats.cpp:82` | 1000 ms | only while `SystemStats.active` | CPU, memory, GPU and network sample. Stopped by `setActive(false)` at `:96`. |
| `windows/deps/quickshell/src/windows/system/system_monitor.cpp:1468` | 1000 ms | only while `SystemMonitor.active` | PDH query on a worker thread that waits on a condition variable while inactive. |
| `windows/deps/quickshell/src/windows/system/calendar_events.cpp:839` | schedule dependent | only while a calendar page is active | Calendar sync. |

The shell bounds both native samplers with one binding each: `windows/shell/shell.qml:366` computes
`statisticsVisible` from the dashboard drawers, and `:370` and `:375` write it to `SystemMonitor.active` and
`SystemStats.active`. With no dashboard open both are stopped, so the expensive PDH and GPU work does not
happen at idle. That gating is worth keeping exactly as it is.

One item outside `src/windows/` matters for completeness. `windows/deps/quickshell/src/core/clock.cpp:61`
reschedules a timer to the next second boundary when precision is seconds; that is the wakeup source behind
`Time.qml`. The crash handler at `src/windows/crash/handler.cpp:139` sleeps for 30 s and is reached only
while reporting a crash.

## 6. Ranked candidates

Cost is wakeups/min multiplied by the rough work above. The ranking is an estimate from source, not a
profile. A candidate is marked `likely worthwhile` when each expiry does real work (a process creation, a
network request, or JavaScript allocation and binding churn) and the count is at least about one a minute.
It is marked `needs measurement` when the per-expiry work is a cheap system call, whatever the count,
because the idle scenario may not resolve it. `leave alone` means the mechanism carries a documented
compatibility or correctness role, or the remaining total is negligible.

| Rank | Candidate | Where | Wakeups/min | Rough work | Mark |
| --- | --- | --- | --- | --- | --- |
| 1 | `Time.qml` seconds precision | shell | 60 | Locale format, string split, about ten bar bindings re-evaluate | likely worthwhile |
| 2 | Recorder `--status` poll | shell | 4 | Child process creation, stdout collect, reply parse | likely worthwhile |
| 3 | Quota 60 s background refresh | shell | 1 | One or two HTTP requests, JSON parse, cache write | likely worthwhile |
| 4 | Keyboard layout poll | backend | 120 | Layout enumeration and compare | needs measurement |
| 5 | Window tracker sweep | backend | 6 | `IsWindow` per tracked window | needs measurement |
| 6 | Wallpaper Engine poll | shell | 1 to 4 | Python bridge status scan | needs measurement |
| 7 | Power profiles fallback refresh | backend | 6 | Active scheme read | needs measurement |
| 8 | UPower poll | backend | 2 | `GetSystemPowerStatus` | needs measurement |
| 9 | Bluetooth battery poll | backend | 1 | WinRT battery read per device | needs measurement |
| 10 | Weather hourly fetch | shell | 0.017 | HTTPS request and JSON parse | leave alone |
| 11 | Toast access backstop | backend | 6 | WinRT access read, opt-in only | leave alone |
| 12 | Late input report | backend | 6 | Three atomic exchanges | leave alone |
| 13 | Tray brief poll | backend | 40 | Tray snapshot, `brief` mode only | leave alone |
| 14 | Taskbar reconcile | backend | 240 or 30 | Window enumeration, `hideTaskbar` only | leave alone |
| 15 | Hotkey release poll | backend | 4000 while held | Key state read, only during a held chord | leave alone |
| 16 | Wi-Fi scan | backend | 7.5 | WLAN scan, list visible only | leave alone |
| 17 | Volume peak | backend | 1818 | COM peak read, meter visible only | leave alone |
| 18 | Dashboard samplers | backend and shell | 30 to 120 | PDH and CPU samples, dashboard open only | leave alone |
| 19 | Capture wait loop | shell | 3750 | Glazier visibility poll, capture only | leave alone |
| 20 | Recording countdown | shell | 1200 | Clock tick, recording only | leave alone |

Items 11 and 12 cost almost nothing per expiry and carry a consent or diagnostic role. Items 13 to 20 are
gated by a panel, a recording, an opt-in or a compatibility mode, so their high counts do not apply to idle.

### 6.1 `Time.qml` seconds precision

Mechanism. Set `SystemClock.precision` from a demand binding instead of the constant at
`windows/shell/adapters/services/Time.qml:56`. Seconds when a visible consumer needs them, minutes otherwise.
Today the only consumers of seconds are the bar clock loader gated by `Config.bar.clock.showSeconds`
(`modules/bar/components/Clock.qml:115`) and the dashboard clock loader gated by
`Config.dashboard.showClockSeconds` (`modules/dashboard/dash/DateTime.qml:63`). Both default to off
(`plugin/src/Caelestia/Config/barconfig.hpp:105`, `plugin/src/Caelestia/Config/dashboardconfig.hpp:30`).
`Time.date`, `Time.hourStr`, `Time.minuteStr`, `Time.amPmStr`, `Time.timeStr` and each `Time.format()` call
with a date-only format are minute-resolution, so nothing else observes the extra ticks.

Behaviour to preserve. A clock that shows seconds must still tick once per second and must leave the correct
second immediately when it becomes visible. `Time.format("ss")` must not read `00` while a seconds display is
on. Enabling the setting at runtime and opening the dashboard with `showClockSeconds` enabled must both
re-arm seconds on the same frame, which `SystemClock::setPrecision` already does by calling `update()`.

Metric. Idle CPU time for the shell process and timer expiry count over a fixed idle window, from the
scenario the #26 suite publishes for idle. Watch the launcher latency and dashboard frame scenarios for a
regression, because both paths rebuild `Time` consumers.

### 6.2 Recorder status poll

Mechanism. One process creation every 15 s to learn a state that changes only on a tray or hotkey action.
Either raise the idle interval well past 15 s and keep the short interval while the recorder is visible, or
replace the poll with a state push from the recorder helper. The adapter already exists from startup even
with every drawer closed, because `windows/shell/adapters/utils/Paths.qml:29` binds `recsdir` to
`Recorder.outputDir`, so the poll is not deferred until the utilities panel first opens. The existing 16 s
timeout at `windows/shell/adapters/services/Recorder.qml:367` and the `--status` shape already tolerate a
slow reply, so an interval change touches no protocol.

Behaviour to preserve. The utilities recording card and the record hotkey at
`windows/shell/adapters/daemons/Shortcuts.qml:69` must both still see a recording that was started outside
the shell before the next user action. A stale state must not let the shell start a second capture.

Metric. Child process creation count per idle window, shell CPU time, and the recorder card's state latency
after an external start. The #26 idle scenario covers the first two; a scripted external `--start` covers
the third.

### 6.3 Quota background refresh

Mechanism. `windows/quota/services/Quota.qml:1279` refreshes every 60 s whenever the CPA config is present,
even with the drawer closed. The drawer already refreshes on open: the handler at
`windows/quota/modules/quota/Wrapper.qml:41` calls `Quota.refresh()` when the cached data is older than 30 s.
Stop or lengthen the timer while `clockHolders` is zero and keep the open-time refresh.

Behaviour to preserve. Opening the drawer still shows the last known summary immediately from
`quota-summary.json`, then a fresh one. The CPA key is read only while the integration is enabled
(`windows/quota/services/Quota.qml:355`). A refused key still suppresses requests, as the header comment at
`windows/quota/services/Quota.qml:38` describes, and a network request must not start from a closed drawer.

Metric. Outbound request count and shell CPU time per idle window, plus time to first complete quota render
after a drawer open, from the panel scenario. The #26 suite must show both the drop and the unchanged open
latency.

### 6.4 What would promote a `needs measurement` item

- Keyboard layout poll: a backend event for layout and toggle changes, or evidence that 120 cheap wakeups a
  minute change idle CPU or timer counts. Until then the fallback comment at `keyboard.cpp:194` stands.
- Window tracker sweep: proof that destroyed windows actually arrive as events, so the sweep can be removed
  rather than lengthened.
- Wallpaper Engine poll: measurement that the enabled-integration scenario is a meaningful share of idle
  cost. The default leaves it off.
- Power profiles and UPower: evidence that the notifications miss a value in practice. Both already have
  event paths.
- Bluetooth battery: evidence that a device battery read is expensive enough to matter at one per minute.

## 7. Deliberately idle-safe

These are already correct and should not be disturbed:

- Native resource sampling runs only while a dashboard is open. See the two `Binding` objects at
  `windows/shell/shell.qml:370` and `:375`.
- Notification mirroring starts off. Access observation, and its 10 s backstop, starts only after the
  service opts in at `windows/services/notifications/NotificationsService.qml:513`.
- Wallpaper Engine, CPA quota, notification mirroring, the desktop clock and the visualiser are off or
  unconfigured in the seeded profile.
- Every `FileView` watcher is event driven. None polls.
- The scheme helper, the banner helper and the quota keepalive block on stdin between requests. They are
  resident memory, not wakeups. Their resident size belongs to the long-session growth scenario in #26, not
  to this inventory.

## Limits

- The shell was not run and no profile was captured for this page. Every statement is from source.
- Wakeups per minute is arithmetic on the declared interval. Qt may coalesce or delay timers, and a sleeping
  display or a suspended process changes the real count.
- Per-expiry cost is a description of the code path, not a timing. The #26 suite supplies the detection
  limit, and an idle CPU difference below that limit would be inconclusive rather than zero.
- The backend rows describe the pinned submodule revision in `windows/sources.lock.json` and need a paired
  backend change before any shell measurement can attribute a difference to them.
- Continuous frame rendering by the wallpaper, the blur pipeline and panel effects is outside this
  inventory. It is not timer work, and the GPU and frame scenarios in #26 cover it.
