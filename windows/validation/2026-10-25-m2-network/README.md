# M2 Windows network validation, 2026-10-25

ERM-500's bounded network slice: default-off `NetworkService`/`Nmcli` adapter,
thin `Quickshell.Windows.Network` wrapper, and the original Caelestia network
popout in an isolated host. This archive records the clean-source fixture run,
native Disabled/ReadOnly smoke at 150% and 175% (negative secondary origin),
the M1 bar/session regression, and the media/battery fixture regressions.

This is not live Wi-Fi control, denial/recovery or a complete M2 milestone.
Nothing here was run in `Interactive` mode; no radio, connect, disconnect,
forget or scan was requested, and no input was synthesized.

## Sources and tools

- Root revision: `475c7a271f2e57f8ff3605adf3bc92d4d9044261` (`475c7a27`,
  `t3/network-service-ui`), clean (`sourceDirty=false`) for every run.
- Backend gitlink and `windows/sources.lock.json`:
  `1401042969e4b7ab3cfb314fc76945ab081db3de` (`14010429`), unchanged by this
  slice. No submodule, pin or build change was made.
- Qt `6.11.2` MSVC 2022 x64; `qml.exe` SHA-256
  `24994D434962751713F0C8932B356104B0849572B95765DAD50C13DA6BE3FA20`.
- Native shell executable `qs.exe` SHA-256
  `22B69FFE0523F8FFDB86C22E1669A36B2C8DCAEA97B19754000EC7455345AF22`; build
  record SHA-256 `3FA201EE45FC755B663FF122090B617D222BBFD99352B18F490B003F0C14FED1`.
  The shared native build under `D:\AiStack\caelestia-windows\windows\.local\build`
  was reused, not rebuilt or modified.

Key staged sources (SHA-256 from the run's staged `sources.json`, copied as
[network-readonly-screen1-staged-sources.json](evidence/network-readonly-screen1-staged-sources.json)):

| source | staged | SHA-256 |
| --- | --- | --- |
| `windows/services/network/NetworkService.qml` | `services/NetworkService.qml` | `B24060D09712CEB9D0272E8548991AB5E6599B71984BD246EBAA96FD5DCF233D` |
| `windows/services/network/Nmcli.qml` | `services/Nmcli.qml` | `E499F5DF9DE964B5D1097EA2B834277A38F519EBDD7F0318484FD01A1785B7E8` |
| `windows/services/network/NativeNetworkBackend.qml` | `services/NativeNetworkBackend.qml` | `111008466354AA2ADEF8200AD19C373D350FCDFF8AF24A22627012C609E45821` |
| `modules/bar/popouts/Network.qml` | `modules/bar/popouts/Network.qml` | `A2ADBB091797A13BE800980FD9B868DF904A7952E1C692D6073FAFB9992E762B` |
| `modules/bar/popouts/PopoutState.qml` | `modules/bar/popouts/PopoutState.qml` | `DE8F98AF165FF3921266E611081FF642C33FA9DE74DEAB017DF44F4467D8E183` |
| `components/controls/StyledSwitch.qml` | `components/controls/StyledSwitch.qml` | `0C5FDBC5B79B3637C50EFC8A4F5A55836BA523305BD9DE5A0E5A2E3BD5C5A9AC` |
| `components/controls/CircularIndicator.qml` | `components/controls/CircularIndicator.qml` | `36B5E01A2B673ADF6A8D5E2B5BDFC7617290913574514305FE722BCC7164F223` |
| `components/controls/CircularProgress.qml` | `components/controls/CircularProgress.qml` | `BC3149A4BB55CED00284753EDEF93A6207EBD2C9D9D81E7539F41ACD882F59C3` |
| `utils/Icons.qml` | `utils/Icons.qml` | `717B8043E1E09715C1FB670E241357D8F433B7334EBF73E7DA302B7FE86C9E43` |
| `utils/NetworkConnection.qml` | `utils/NetworkConnection.qml` | `F3DB169DB7E395A31875C7DC7A891327852BD0FC66B4FD5F2D0C25A0B825506E` |
| `windows/network-prototype/shell.qml` | `shell.qml` | `EA6C2CF32DAEDDB9591EDFE7A9433A9B4997F98F5B80DFC164C77B9B0D00FC5C` |
| `windows/shell-prototype/adapters/services/Colours.qml` | `services/Colours.qml` | `10F5466890F72716B7D16662C9CDCA0720D3D5368B3060C077DEE28377EB0755` |

Fixture sources (`NetworkService.qml` `B24060D0...`, `NetworkServiceTest.qml`
`3666A1F44D9A46C329045471AA2D70245B5A8043D0FCC94F511B0C588E249B2D`) are staged
with matching hashes; [network-fixture-result.json](evidence/network-fixture-result.json)
records both.

## Commands and results

All commands ran in native PowerShell with the shared build root.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$build = 'D:\AiStack\caelestia-windows\windows\.local\build'

powershell -NoProfile -File windows/scripts/Test-NetworkPrototype.ps1 -QtPrefix $qtPrefix -BuildRoot $build
# passed: true; 6 runs; output network-validation-20261025-180420-455

powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 -QtPrefix $qtPrefix -BuildRoot $build
# passed: true; 148 assertions

powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 -QtPrefix $qtPrefix -BuildRoot $build
# passed: true; 128 assertions
```

`Test-NetworkPrototype.ps1` records six runs: the offscreen fixture, four
native smoke runs, and the M1 regression. Raw output is
[network-final-harness.out.txt](evidence/network-final-harness.out.txt),
[network-final-media-fixture.out.txt](evidence/network-final-media-fixture.out.txt)
and [network-final-battery-fixture.out.txt](evidence/network-final-battery-fixture.out.txt);
the full harness record is
[network-prototype-result.json](evidence/network-prototype-result.json).

| run | result | detail |
| --- | --- | --- |
| fixture | pass | 329 assertions, no native imports, no hash mismatch, no QML diagnostics |
| Disabled, screen 0 (150%) | pass | `status=disabled`, loader inactive, no popout, 0 commands, 0 scans |
| ReadOnly, screen 0 (150%) | pass | original popout loaded, `status=disconnected`, adapter/radio true, Ethernet connected, controls off, 0 commands, 0 scans |
| Disabled, screen 1 (175%, x=-3840) | pass | same disabled construction policy |
| ReadOnly, screen 1 (175%, x=-3840) | pass | same settled observation |
| M1 regression, screen 0 | pass | original bar/session smoke |

Each native run exits `0`, captures a PNG, records `CAELESTIA_NETWORK_PASS`,
and contains no runtime `WARN`/`ERROR`/`FATAL` line. Initial and final states
are identical in each run (the harness compares policy, adapter/radio/
connection, list, Ethernet and command fields). The 520x680 logical window
reports `dpr=1.5` on the primary and `dpr=1.75` on the negative-origin
secondary.

### Native observation

The pinned backend reported a present Wi-Fi adapter with radio on, no
associated network, `wifiStatus=disconnected`, and an active Ethernet link
(`hasInternet=true`). The list was available and empty (`networkCount=0`), so
the original popout rendered its Ethernet section (the upstream
`activeEthernet ? "ethernet" : "wireless"` routing) with one connected device
whose interface name is unknown. Both ReadOnly runs recorded exactly:

```json
{"status":"disconnected","adapterPresent":true,"radioOn":true,
 "locationDenied":false,"connected":false,"activeSsid":"","limited":false,
 "hasInternet":true,"listAvailable":true,"listHidden":false,
 "listVisible":false,"networkCount":0,"ethernetConnected":true,
 "ethernetDeviceCount":1,"ethernetControlSupported":false,
 "ethernetConfigSupported":false,"initialized":true,
 "controlsEnabled":false,"commandsSent":0,"scansRequested":0,
 "popoutLoaded":true,"popoutControlsEnabled":false,
 "popoutNativeConnect":true,"popoutEthernetControlAvailable":false,
 "statusIcon":"cable"}
```

No access point, connected Wi-Fi, radio-off, location-denied or no-adapter
state occurred on this hardware during the recorded runs. Those transitions
are fixture-validated only.

Screenshots:

- [Disabled 150%](evidence/network-disabled-screen0-150.png)
- [ReadOnly 150%](evidence/network-readonly-screen0-150.png)
- [Disabled 175%](evidence/network-disabled-screen1-175.png)
- [ReadOnly 175%](evidence/network-readonly-screen1-175.png)
- [M1 regression](evidence/m1-regression-screen0-150.png)

### Desktop state

[Before](evidence/desktop-before.json) and
[after](evidence/desktop-after.json) match: Explorer PID 9252 and KSG Shell PID
24108 are unchanged, both monitor physical work areas are identical, taskbar
state flags are `1` (auto-hide) with `alwaysOnTop=false`, and the foreground
window/process did not change. A concurrent agent's `qs` prototype was present
in the before snapshot and gone afterwards; it is not part of this slice. No
harness-owned prototype process remained after the harness. (The identity gate
excludes transient `qs` entries so concurrent agent smoke runs do not fail this
run; each harness-owned run is separately required to exit cleanly with no
diagnostics.)

## Localized edits to original upstream files

Only [Network.qml](../../../modules/bar/popouts/Network.qml) changed. Added
hooks all default to upstream behavior:

- `controlsEnabled=true` gates the radio toggle, access-point action and
  Ethernet action.
- `nativeConnectingSsid=""` selects the observed connecting SSID; empty keeps
  the upstream `connectingToSsid` marker.
- `statusText=""` renders no extra line; the host supplies command feedback in
  the popout's existing small text style.
- `nativeConnect=false` keeps `NetworkConnection.handleConnect`; `true` emits
  `connectRequested` for the facade.
- `ethernetControlAvailable=true` disables only when a host reports no backend
  control.
- `Toggle` gained `toggleEnabled=true` and passes it to `StyledSwitch.disabled`.

No upstream file gained a Windows visual approximation. The prototype-only
fixed-palette adapter `windows/shell-prototype/adapters/services/Colours.qml`
gained `m3outline`, `m3surfaceContainerHighest` and an opaque `layer()`
passthrough because the original `StyledSwitch`/`CircularIndicator` use them;
this adapter is not upstream and remains opaque.

## Backend gaps found

- No `Network` initialization/ready/error property or signal. A WLAN open
  failure only logs at debug level and leaves `wifiAdapterPresent=false`
  (`network_wifi.cpp:168-173`), conflating "no adapter" with a service
  failure. `initialized` in this slice is a bounded four-second adapter
  heuristic, not a backend capability.
- The constructor starts connectivity/WLAN observation and performs one
  available-network query even when the list is hidden
  (`network.cpp:15-25`, `network_wifi.cpp:189-194`). The adapter cannot prevent
  that startup query without a backend change.
- `connectToNetwork()` has no membership or security validation: an unknown
  SSID is treated as an open network and can write a profile with an empty
  password (`network.cpp:41-54`, `network_wifi.cpp:409-428`). The adapter
  enforces membership, active and credential guards before calling it.
- Radio writes have no result; a refusal warns and opens Windows Settings
  (`network_wifi.cpp:250-255`). Disconnect and forget have no result
  (`network_wifi.cpp:451-460`); scans have no per-scan result
  (`network_wifi.cpp:260-271`). These are reported as requested/unverified.
- A denied current-connection query returns early and can leave the previous
  SSID in native state (`network_wifi.cpp:369-372`). While location is denied
  the adapter reports no active SSID.
- Ethernet is limited to `ethernetConnected`/`hasInternet`
  (`network.hpp:27-41`); there is no device list, name, speed, usage, address or
  control. The typed `EthernetDevice` reports the connected state with unknown
  names and empty advanced fields, and the Ethernet action is disabled.

## Untested

- `-NetworkMode Interactive`, the radio toggle, connect/disconnect/forget,
  rescan and any visible-list scan were not run.
- Connected Wi-Fi, access-point rows, connect success/failure, stale/removed
  access points and location denial/recovery are fixture-validated only. The
  typed `Nmcli.AccessPoint` type reference compiled with the original popout,
  but no native access-point row was instantiated because the visible list was
  empty; the typed delegate assignment is therefore not natively exercised.
- The password/saved-profile UI, IPv4 configuration, hidden networks,
  autoconnect, saved-connection detail and Ethernet speed/usage/control are not
  implemented.
- Native radio-off, no-adapter and location-denied states were not produced by
  this hardware; the four-second settle-expiry path was not exercised because
  native observation arrived first. That path is not fixture-covered either.
- 100% scaling was not exercised; native 150% and 175% were.
- No real hardware denial, recovery, privilege change or retry was tested.
