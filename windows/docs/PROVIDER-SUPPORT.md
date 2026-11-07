# Windows provider support

This is a source-trace map for the Windows UI that is staged by
[`windows/shell/sources.json`](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/sources.json).
The trace baseline is shell `2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44`,
backend `593610a42f986c6e3c6a756a3e4cbb5929602bad`, Glazier
`37f795041cbbb32ed46cba103f3f000a3a99ac13`, and M3Shapes
`32ad9ce328bb77ed349b40a3be10ee9ea610b8ab`. These are code-navigation pins.
The initial named source candidate is `provider-support-source-20261106`, shell
`b3e632a62ef784e33a671f58caf377283b1d5d3b`. That historical candidate used
backend `e6039b2b9cbb35b97473bda4dcc3f12789ae7f0c` and included the
availability-label correction below. The trace pins above now include the
merged backend safety repairs and shell-side opaque Wi-Fi selection identity;
they do not imply those changes were present in the initial candidate.
It is a source and fixture candidate, with no release, installed-package,
desktop or hardware qualification. The machine-readable copy is
[`provider-support.json`](../tests/provider-support.json); its traceability
check is [`Test-ProviderSupport.ps1`](../tests/Test-ProviderSupport.ps1).

Capture source update: the maintained helper now lives in `windows/capture`
and builds as `caelestia-capture.exe`. Its source trace is
[`f637fcdc6bc1a52e2a405ef1935b199276d06a9c`](https://github.com/KldsSeeGhosts/caelestia-windows/tree/f637fcdc6bc1a52e2a405ef1935b199276d06a9c/windows/capture).
The original Glazier pin above and the older table links below remain origin
and historical navigation references, not the maintained helper's source SHA.
The machine-readable capture row records the updated source links. Source
integration is not live capture, exact-package or hardware acceptance.

“Staged” means a source file is included in the production staging map. It does
not mean the corresponding native component is always loaded: several services
are default-off, read-only, or separately opt-in. The map below describes
source-exposed operations, not universal device coverage. Source inspection and
fixture evidence do not prove behavior on every Windows build, driver, device,
display, or application.

| Provider | UI entry → staged adapter → provider | Exposed operations | Conditions and current boundary |
| --- | --- | --- | --- |
| Shell / session | [Session menu](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/session/Content.qml) → [SessionService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/session/SessionService.qml) → [Windows Session facade](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/session/NativeSessionBackend.qml) → [native session API](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/session.cpp) | Allowlisted lock, log out, shutdown, restart, suspend, hibernate, and firmware-reboot requests; hibernation capability observation. | Observation and dispatch have separate opt-ins. The native methods return `void`; a call is `requested`, not accepted or completed. Combined suspend-then-hibernate is unsupported. |
| Tiling | [Window management settings](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/WindowManagementPage.qml) → [TilingService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/tiling/TilingService.qml) → [native tiler](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/tiling.cpp) | Observe eligible windows; optionally tile configured applications, apply gaps/border options, and preview/commit window drops. | Off by default; Observe and Interactive are distinct. No-screen, empty eligibility, ownership conflicts and individual placement failures remain visible refusals/errors. Public acceptance: [tiling/window interaction](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/12). |
| Audio | [Audio page](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/AudioPage.qml) → [AudioService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/audio/AudioService.qml) → [Windows audio worker](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/services/pipewire/pw_session_worker.cpp) | Observe default inputs/outputs and streams; change supported endpoint selection, mute and volume. | Input, output and application sessions can differ in readiness. A healthy but empty endpoint/session model is not the same as failed initialization. Device, privacy-setting and recovery acceptance: [audio owner](https://github.com/KldsSeeGhosts/caelestia-windows/issues/31). |
| Battery / power profile | [Battery popout](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/bar/popouts/Battery.qml) → [BatteryService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/battery/BatteryService.qml) and [PowerProfilesService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/battery/PowerProfilesService.qml) → [native provider](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/services/upower/device.cpp) | Observe power/battery state and mapped effective power profiles; separately gated profile writes report their result/readback. | Desktops may have no battery. Unknown or unmapped profile values do not become a guessed “Balanced” value. Laptop/power-profile acceptance: [power owner](https://github.com/KldsSeeGhosts/caelestia-windows/issues/32). |
| Bluetooth | [Bluetooth settings](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/BluetoothPage.qml) → [BluetoothService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/bluetooth/BluetoothService.qml) → [Windows Bluetooth provider](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/bluetooth/bluetooth.cpp) | Observe adapter/device state; request supported discovery, connect/disconnect, forget and explicit pairing. | Requires a functioning adapter and radio. Hardware/policy blocking, radio-off, scan timeout and an empty device list are distinct. PIN/passkey completion can remain in Windows. |
| Brightness | [Bar scroll action](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/modules/bar/Bar.qml) and per-screen OSD → [BrightnessService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/brightness/BrightnessService.qml) → [route selector](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/brightness.cpp) | Read and request per-screen adjustment only when a safe screen/target route is established. | WMI, built-in LCD, DDC/CI, HDR SDR-white, and software dimming are conditional backend routes, not a promise for every display. External-monitor identity, ranges and recovery remain hardware acceptance: [brightness owner](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/13). |
| Network / Wi-Fi | [Network settings](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/NetworkPage.qml) → [NetworkService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/network/NetworkService.qml) → [WLAN provider](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/network_wifi.cpp) | Observe radio, scan results, active connection and limited wired connected state; separately gated Wi-Fi radio/connect/disconnect/forget/rescan requests. | Location denial hides nearby Wi-Fi results. A successful empty refresh differs from no adapter or initialization/subscription failure. The shell sends no password. [A new protected network is completed in Windows Settings](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/network/AddNetworkPage.qml); Ethernet controls, VPN profile changes and new protected profiles are not implemented here. WLAN acceptance: [network owner](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/14). |
| Media | [Dashboard media](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/dashboard/Media.qml) → [PlayersService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/media/PlayersService.qml) → [GSMTC worker](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/services/mpris/gsmtc_worker.cpp) | Observe Windows media sessions; send only transport operations the selected application advertises. | Requires a Windows-exposed session. A healthy zero-session scan is `empty`; an app can lack a requested transport action. |
| Notifications | [Notification settings](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/ServicesPage.qml) → [NotificationsService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/notifications/NotificationsService.qml) → [Windows toast mirror](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/services/notifications/toast_mirror.cpp) | Local shell notification handling/history; optional mirroring of Windows notifications after explicit consent. | Permission denial/revocation disables mirroring, not necessarily local notifications. Ownership/init failure is unavailable, not an empty notification list. Notification and fullscreen policy acceptance: [notifications owner](https://github.com/KldsSeeGhosts/caelestia-windows/issues/30). |
| Desktop control | [Workspace bar](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/bar/components/workspaces/Workspaces.qml) → [Hypr facade](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/hypr/HyprService.qml) → [native dispatcher](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/hyprland/dispatcher.cpp) | Observe supported window/foreground/workspace state; send allowlisted workspace switch/move and graceful close requests. | Observation/dispatch are opt-in. Workspace moves require a supported Windows virtual-desktop interface family (26100/26200/26300) and provider availability. Dispatch is `void`, so sent is not completed. Physical held-chord/drag acceptance: [desktop interaction owner](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/12). |
| Capture / recording | [Default hotkeys](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/defaults/windows/keybinds.json) → [Glazier adapter](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/services/Glazier.qml) and [Recorder adapter](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/services/Recorder.qml) → [pinned Glazier capture](https://github.com/KldsSeeGhosts/glazier/blob/37f795041cbbb32ed46cba103f3f000a3a99ac13/src/capture.rs) / [recording](https://github.com/KldsSeeGhosts/glazier/blob/37f795041cbbb32ed46cba103f3f000a3a99ac13/src/recording.rs) | Launch the screenshot picker/editor; request recording start/stop/pause/resume and observe provider state/finalization. | The interactive live shell and bundled executable are needed. Executable-path availability is not host readiness or completed capture. A detached screenshot command has no file-completion receipt. Recording must be confirmed by provider state/journal. |
| Idle inhibition | [Keep-awake card](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/utilities/cards/IdleInhibit.qml) → [IdleHold facade](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/imports/Caelestia/Services/IdleHold.qml) → [power request API](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/idle_power.cpp) | Acquire/release a Windows idle-inhibition request. | Live user action only. A failed acquire or clear must remain unavailable/failed/held as reported, not be called success. |
| Keyboard | [Keyboard-layout popout](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/bar/popouts/kblayout/KbLayoutModel.qml) → [Hypr native wrapper](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/hypr/NativeHyprBackend.qml) → [Windows keyboard provider](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/keyboard.cpp) | Observe foreground input layout/lock keys and request a layout switch for a validated target application. | Observation is tied to the foreground input thread. TSF/registry fallback, CJK and substituted IME profiles remain acceptance, not an all-keyboard claim: [keyboard owner](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/15). |
| Tray | [Bar tray](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/bar/components/Tray.qml) → [TrayService](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/tray/TrayService.qml) → [native tray host](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/services/systray/host.cpp) | Observe eligible notification-area items; conditionally activate and invoke native menus. | Requires Explorer/native hook readiness; observation and activation policy are distinct. A healthy host with zero eligible icons is empty, not unavailable. |
| Wallpaper | [Wallpaper picker](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/wallandstyle/WallpaperSelect.qml) → [Windows wallpaper adapter](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/services/Wallpapers.qml) → [native wallpaper provider](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/wallpaper.cpp) | Select a wallpaper and coordinate the desktop background/underlay with an optional WallpaperEngine. | Current desktop-host/underlay behavior is source-described, not newly qualified here. Wallpaper physical acceptance remains controlled by [its owner](https://github.com/KldsSeeGhosts/caelestia-windows/issues/25); no live wallpaper test is part of this work. |
| Clipboard picker | [Clipboard history contract](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/clipboard/README.md) → [native wrapper](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/clipboard/NativeClipboardBackend.qml) → [Caelestia Windows plugin](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/plugin/src/Caelestia/Windows/Clipboard/windowsclipboard.cpp) and [backend clipboard API](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/clipboard.cpp) | Read Windows' own history for the picker; preview/paste/remove/clear and open Windows clipboard settings. | Enabled by default but no default key binding. Windows history must be enabled and accessible; Caelestia does not enable it. Support-bundle v1 has no clipboard provider ID, so do not imply current clipboard health export. Never include clipboard content in diagnostics. |

## Result vocabulary

Keep provider/category state separate from operation progress. Use only these
seven categories in support-facing summaries and retain a nullable value when
the information was not observed:

| Category | Meaning |
| --- | --- |
| `supported` | This operation has an implemented provider route. It does not prove an individual request completed. |
| `unsupported` | This operation is not implemented or is excluded on this configuration. |
| `denied` | An explicit permission, policy or provider refusal was observed. |
| `unavailable` | The provider/input is absent, failed to initialize, or has no trustworthy current observation. |
| `transient` | The provider is starting, reconnecting, or otherwise in a bounded temporary state. |
| `failed` | An attempted operation has an observed failure result. |
| `empty` | A successful observation returned no items. It is not interchangeable with `unavailable`. |

The integrated [opt-in support-bundle v1](https://github.com/KldsSeeGhosts/caelestia-windows/issues/8)
contract defines nullable `ready`, `requested`, `accepted`, and `completed`
booleans with this category vocabulary. The exporter is present in this trace
baseline. Use those fields as follows:

| Field | Report only when |
| --- | --- |
| `ready` | Readiness was observed; do not infer it from component construction or an initialized flag. |
| `requested` | A caller/user expressed intent. |
| `accepted` | The provider explicitly reported accepting dispatch. A QML return value or void call alone is insufficient. |
| `completed` | A provider result or observed readback confirms the outcome. Async acceptance alone is not completion; unknown/not observed is `null`. |

The v1 support export reads no live providers by default. Provider rows are
unavailable/not-collected until a caller supplies an allowed offline snapshot.
Its identity trust is `declared-unverified`, not a package verifier. This page
aligns vocabulary only; it does not add a live endpoint or assert that every
provider already emits all four fields. The fixed v1 provider IDs are
`shell`, `tiling`, `audio`, `battery`, `bluetooth`, `brightness`, `network`,
`media`, `notifications`, `desktop`, `capture`, `idleInhibit`, `keyboard`,
`tray`, and `wallpaper`. Clipboard is deliberately called out separately as
`Clipboard picker` because that ID set has no clipboard entry.

## Optional API boundaries

- The ordinary staged Hypr facade rejects generic `fullscreen` dispatch as
  unsupported. The pinned native dispatcher retains fullscreen operations that
  can be reached by custom bindings. That is optional/custom-binding exposure,
  not a default UI control.
- The pinned backend retains display-topology mutation APIs, but the current
  staged UI has no default path that calls them. Do not describe generic
  topology mutation as a default supported UI capability.
- The Windows clipboard adapter uses the Caelestia Windows plugin over
  Windows' clipboard history. The inherited clipboard implementation and its
  store are not the active picker route.
- Screenshots and recordings use the maintained first-party capture helper,
  with a native managed-host owner. The compatibility-named Glazier adapter is
  not a separate dependency. See the capture source update above; live capture
  and final candidate acceptance remain unverified here.

Sources for those boundaries: [Hypr facade policy](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/hypr/HyprService.qml),
[native dispatcher](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/hyprland/dispatcher.cpp),
[display API](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/blob/593610a42f986c6e3c6a756a3e4cbb5929602bad/src/windows/system/displays.hpp),
and [clipboard architecture](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/services/clipboard/README.md).

## Source findings and evidence limits

Two presentation/lifecycle gaps are visible in the pinned baseline:

1. The Glazier and recording rows in
   [`ServicesPage.qml`](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/adapters/modules/nexus/pages/ServicesPage.qml)
   displayed “Ready” when `Glazier.available` or `Recorder.available` was true.
   This change labels those rows “Available” instead.
   Those booleans establish an executable path/provider availability, not a
   running host, successful command, completed screenshot, or saved recording.
2. Shell quit/restart handlers call `Glazier.stopHost(...)` but ignore its
   boolean result in
   [`shell.qml`](https://github.com/KldsSeeGhosts/caelestia-windows/blob/2bed3ddf26a240b967705aba2e5f9e4ee5bb0e44/windows/shell/shell.qml).
   The pinned shell therefore has no surfaced stop outcome at that call site.
   The [lifecycle repair](https://github.com/KldsSeeGhosts/caelestia-windows/issues/4)
   owns that correction and its integration evidence.

These are source findings, not claims of a reproduced live failure. Capture
lifecycle acceptance remains with the public [recorder owner](https://github.com/KldsSeeGhosts/caelestia-windows/issues/28).
The managed-host implementation and first-party source move do not establish
those live acceptance results.

## Maintaining this map

When the staging map, a pinned dependency, or a public UI/provider capability
changes:

- Re-trace the reachable UI entry through staged adapter and actual provider;
  update the matrix's staging destinations and pinned source links together.
- For a pin change, update the baseline and repository revision, verify each
  local checkout and lock entry, then rerun the traceability check.
- Add a public capability only with its exposed operation, prerequisites,
  denied/unavailable/transient/failed/empty examples, and a public acceptance
  owner when hardware or OS coverage is still unverified.
- Change bundle provider IDs or fields only with the current bundle contract.
  Keep identity `declared-unverified`, caller-supplied observations offline,
  and unobserved operation phases null. Never imply all-hardware support.

This change traces source files and staging destinations. It did not run the
provider fixture suites, build or package the shell, inspect a live desktop,
exercise permissions, or test physical hardware. Existing fixture files test
their fixture/component contracts only unless a separate result identifies a
real provider and exact candidate. Hardware-dependent acceptance remains with
the public [audio](https://github.com/KldsSeeGhosts/caelestia-windows/issues/31),
[battery](https://github.com/KldsSeeGhosts/caelestia-windows/issues/32),
[brightness](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/13),
[network](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/14),
[keyboard](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/15),
[desktop interaction](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/12),
[notifications](https://github.com/KldsSeeGhosts/caelestia-windows/issues/30),
[capture](https://github.com/KldsSeeGhosts/caelestia-windows/issues/28), and
[wallpaper](https://github.com/KldsSeeGhosts/caelestia-windows/issues/25)
owners. No all-hardware or all-Windows-build claim follows from this map.
