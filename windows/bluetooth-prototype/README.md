# Windows Bluetooth prototype

ERM-501's bounded M2 Bluetooth slice projects the pinned backend's
`Quickshell.Bluetooth` adapter and devices through a default-off adapter and
loads the **original** Caelestia Bluetooth status icon and popout in a separate
native window. No Bluetooth control is reimplemented.

## Scope and the original components

The host stages:

- [`modules/bar/components/status/BluetoothStatus.qml`](../../modules/bar/components/status/BluetoothStatus.qml),
  the original bar status icons;
- [`modules/bar/popouts/Bluetooth.qml`](../../modules/bar/popouts/Bluetooth.qml),
  the original popout with the radio/discovering toggles, device rows with
  connect/forget actions, and the "Open settings" button;
- their original support components (`PopoutState`, `StyledSwitch`,
  `IconTextButton`, `TextButton`, `CircularIndicator`, `CircularProgress`,
  `Icons`) and the fixed palette.

Both original components import `Quickshell.Bluetooth` directly, so they are
instantiated through `Loader`s only after the observation opt-in. A disabled run
resolves no native singleton, starts no WinRT worker and creates no status or
popout item. The window is at most 560x700 logical pixels, inset 80 from the
chosen screen. Escape closes an interactive run; smoke runs take no input.

The full bar, popout wrapper/Nexus, network and other service panels are not
staged.

## Service states

[`BluetoothService.qml`](../services/bluetooth/BluetoothService.qml) imports no
native module, owns no wall-clock timer and has no process/IPC calls. The facade
[`Bluetooth.qml`](../services/bluetooth/Bluetooth.qml) owns a 500 ms clock and
calls `tick(Date.now())`; fixtures drive `tick()` directly. The native facade
[`NativeBluetoothBackend.qml`](../services/bluetooth/NativeBluetoothBackend.qml)
is loaded by URL only after opt-in.

| state | meaning |
| --- | --- |
| `disabled` | observation opt-in absent; no native backend, status or popout |
| `initializing` | backend present, first adapter observation not settled |
| `no-adapter` | bounded first-observation window expired with a null adapter |
| `blocked` | native radio reports the hardware/policy blocked state |
| `off` | native radio is disabled |
| `radio-pending` | radio is enabling or disabling |
| `on` | radio is enabled; devices are observable |
| `unknown-radio` | native adapter state is not one of the known values |
| `error` | the native backend component failed to load |

`no-adapter` is deliberately worded as a bounded observation, not a completed
Windows scan. The pinned backend keeps `WinBluetooth::isScanned()` and
`scanned(hasAdapter)` in C++ and `BluetoothQml` publishes only
`defaultAdapter`/`adapters`/`devices` (`bluetooth.hpp` lines 32, 67-77;
`bluetooth.cpp` lines 37-41, 119-126), so QML cannot distinguish "no adapter"
from "worker has not scanned yet". `initializationTimeoutMs` (8 s) bounds that
ambiguity. The native adapter state mapping also folds `RadioPower::Off` and
`RadioPower::Unknown` into `Disabled` and only `RadioState::Disabled` into
`Blocked` (`adapter.cpp` lines 24-30, 58-66); `off` therefore covers unknown
power, and this is recorded as a backend gap rather than presented as proof.

Devices are projected only while an adapter is present, so an adapter removal
hides a retained model immediately. Stale/removed objects and foreign objects
fail list membership and cannot be controlled.

## Bounded settling

- **Discovery** is never started by construction or observation. Once an
  explicit interactive request is observed, a 30 s window applies; expiry turns
  `adapter.discovering` off once and sets `discoveryTimedOut`. A read-only
  observer never stops discovery. The native worker ends discovery when the
  unpaired watcher stops on its own (`bt_worker.cpp` lines 810-834).
- **Connect/disconnect** uses a 20 s projection window. The backend's own device
  timeout is also 20 s (`device.cpp` line 20). Expiry removes the device from
  `pendingDevices`, marks `timedOutDevices[address]`, and keeps the original
  spinner hidden through the popout hook. No request is cancelled or re-sent.
- **Pairing** has no native timeout. A pairing observed in interactive mode is
  cancelled with `device.cancelPair()` after the same window; the service then
  points at Windows Settings. Read-only observation never cancels. The backend
  accepts confirm-only and numeric-comparison pairing and rejects
  display/provide-PIN kinds because it has no credential UI
  (`bt_worker.cpp` lines 257-290). That rejection is only logged, so the shell
  cannot label the reason; the original "Open settings" button is the explicit
  delegation path and the service never opens or prompts on its own.

Radio, discovery, connect, disconnect, pair, forget and cancel methods return a
boolean that means **the request was permitted**, never that Windows applied it.
The backend exposes no per-command result. A refused request sends nothing.

Unsupported controls are exposed as always-false flags and refusing methods:
`discoverableSupported`, `renameSupported`, `trustedSupported`,
`blockedSupported`, `wakeSupported`. Their native setters only warn and change
nothing (`adapter.cpp` lines 87-94; `device.cpp` lines 168-188).

## Localized original-UI hooks

[`Bluetooth.qml`](../../modules/bar/popouts/Bluetooth.qml) gained only:

- `controlsEnabled` (default `true`): disables the two original toggles and the
  connect/forget actions in read-only mode. The original disabled switch
  styling is used; no new visual state was added.
- `settingsDelegatesToWindows` (default `false`): when true, the original "Open
  settings" button emits `settingsRequested()` instead of
  `popouts.detachRequested("bluetooth")`. The host opens
  `ms-settings:bluetooth` from that explicit click. Upstream keeps detach.
- `settlingTimedOut` (default `{}`): address-keyed set from the service that
  stops the original loading spinner after the bounded settling window. Empty
  by default, so upstream behavior is unchanged.

The status component was not edited. The fixed palette adapter gained the
upstream `m3surfaceContainerHighest` and `m3outline` defaults used by the
original switch, avoiding an undefined-color warning. No typography, icon or
motion component changed.

## Opt-ins and launch

Both opt-ins are child-process environment variables; the launcher sets them
explicitly so inherited flags cannot enable Bluetooth in another profile.

- `CAELESTIA_WINDOWS_BLUETOOTH=1` constructs the native facade and starts its
  worker after the first frame; it observes the adapter/device models and the
  connected-device battery poll.
- `CAELESTIA_WINDOWS_BLUETOOTH_CONTROLS=1` additionally permits explicit
  radio/discovery/pairing/connection/forget/cancel requests. It is only set for
  a non-smoke `Interactive` run.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Bluetooth -BluetoothMode ReadOnly -Wait
```

`-Bluetooth` selects this entry point. `Disabled` is the default and never
loads `NativeBluetoothBackend.qml`. `ReadOnly` observes the radio/devices and
keeps every control disabled. `Interactive` also enables the control hooks for
explicit user actions; it is not validated here and sends no automatic radio,
discovery or pairing request. Every `-Smoke` run is read-only regardless of the
requested mode.

## Validation

```powershell
powershell -NoProfile -File windows/scripts/Test-BluetoothService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-BluetoothPrototype.ps1 `
    -QtPrefix $qtPrefix
```

`Test-BluetoothService.ps1` stages only the adapter and fixture into Qt's
offscreen `qml.exe`. It rejects native imports, staging hash mismatches and QML
diagnostics. The 182 injected assertions cover:

- disabled construction, no native references and conservative refusal;
- unready backend, initializing, bounded null adapter and adapter re-arrival;
- off/blocked/unknown/enabling/disabling radio states and blocked refusal;
- explicit radio/discovery requests, read-only refusal and no auto-start;
- discovery bounded stop, timeout clearing and read-only non-mutation;
- connecting/disconnecting settling, timeout projection, stale clearing and no
  synthetic requests;
- pairing request, bounded cancel, Settings guidance clearing and read-only
  non-mutation;
- connect/disconnect/pair/forget gates, stale/re-arrived devices, read-only
  device refusal and unsupported setters.

`Test-BluetoothPrototype.ps1` runs the fixture, disabled/read-only smoke on
every measured connected screen, then the original M1 bar/session regression.
Each smoke asserts disabled mode constructs neither the native loader nor the
original components, read-only mode loads both original components with every
control hook false, no discovery starts, and the run produces no QML
diagnostics. Each run records source/staged hashes, initial/final state, logs
and a PNG. The parent owns native hardware-facing checks.

Raw results are under `windows/.local/build/bluetooth-validation-<timestamp>/`.

## Limits

- Native observation on the development machine saw one Intel adapter with the
  radio on and no paired devices. Null/blocked/off radios, paired devices,
  discovery, connect, pair, forget and PIN/passkey delegation are
  fixture-validated only. No radio, discovery, pairing or connection request was
  sent by the native runs.
- Interactive mode is not validated: it is the separate explicit-control opt-in
  and no control was exercised.
- The backend exposes no per-command result. A permitted request is not a
  confirmed success, and Windows refusal is visible only through later native
  state.
- The backend cannot report scan completion or a pairing-kind failure to QML.
  The bounded windows and Settings guidance are the truthful workaround; they do
  not establish a completed hardware scan or the reason a pairing failed.
- No backend source, gitlink or `sources.lock.json` change is part of this
  slice.
