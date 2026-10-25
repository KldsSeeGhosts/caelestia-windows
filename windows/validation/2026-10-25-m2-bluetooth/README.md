# M2 Bluetooth observation prototype, 2026-10-25

This archive records the bounded default-off Bluetooth slice for ERM-501 in the
Caelestia-for-Windows port. It adds a pure service adapter, a native facade and a
bounded host for the **original** Caelestia Bluetooth status icon and popout.
Native runs observed a real Intel adapter with the radio on and **no paired
devices**. No radio, discovery, pairing, connection or forget request was sent.

ERM-501 remains partially validated: interactive controls, a null/blocked/off
radio on real hardware, paired devices, discovery, settling, and PIN/passkey
delegation are fixture-only or untested. This archive does not complete M2.

## Sources and runtime

- Clean root `ddba8d1211c0cde758f9f6cd8b9042e1934cf13c` (`ddba8d12`) on
  `t3/bluetooth-service-integration`.
- Pinned backend `1401042969e4b7ab3cfb314fc76945ab081db3de` (`14010429`).
  The gitlink and `windows/sources.lock.json` are unchanged by this slice.
- Shared native build `D:\AiStack\caelestia-windows\windows\.local\build`
  reused without rebuilding, as instructed. Its `qs.exe` was built from the
  branch base `8a308e7e23af52dca7bf1c15ee9fbb1c8bacca17`; no native source
  changed in this slice. `qs.exe` SHA-256
  `22B69FFE0523F8FFDB86C22E1669A36B2C8DCAEA97B19754000EC7455345AF22`,
  6,417,920 bytes.
- Windows 11 `10.0.26300.0`, Qt 6.11.2 offscreen `qml.exe` SHA-256
  `24994D434962751713F0C8932B356104B0849572B95765DAD50C13DA6BE3FA20`.
- Displays: primary 3840x2160 at 150% (origin 0), secondary 3840x2160 at 175%
  (origin -3840). Both were exercised.

Implementation sources and SHA-256:

| Source | SHA-256 |
| --- | --- |
| `windows/services/bluetooth/BluetoothService.qml` | `DBD81C458CBEDBABD411D24FE8EAC5A83441B8ECE5C04652A57E5A13102F8AA6` |
| `windows/services/bluetooth/Bluetooth.qml` | `834EAC07CBDB61C285128A0E4DBC56C296E62CAA138E6EB863821DF2DC58ECA1` |
| `windows/services/bluetooth/NativeBluetoothBackend.qml` | `F1E01C3962E9103FD3D465C9F801B746638E0B0F8A1D976091F5314D56416A75` |
| `windows/services/bluetooth/BluetoothServiceTest.qml` | `B3A58306D59004218C14AECC7C26DCCAE15AA5446E26729A23BFE781EFD348F3` |
| `windows/bluetooth-prototype/shell.qml` | `6024EC5E4359DDB3CAE5F7B3122408D45520C23118D14CB704787F610D070ECA` |
| `windows/bluetooth-prototype/sources.json` | `771C5CF70D5558FDD28F941E06515D8568DCDCD31BDD9C2D34CE34B5C216A85E` |
| `windows/scripts/Test-BluetoothService.ps1` | `31003184AF7F03F8086B47CEE7E5FFFA98815DD76606734AA777951AD064B305` |
| `windows/scripts/Test-BluetoothPrototype.ps1` | `DAEFF988780DBAF1E8D4B191D02A92CBFD91295003E16ED19937CB0F139B4A85` |
| `modules/bar/popouts/Bluetooth.qml` | `59592FEB710213679EB9768E282D8775907E99F4EF84BCB24F601FC8139C8498` |
| `windows/scripts/Stage-ShellPrototype.ps1` | `03659E51FCDC3F62E9FF0D7CFEC556C201BD683328FF2445E269263E89C33E84` |
| `windows/scripts/Start-ShellPrototype.ps1` | `EEA220BD83E5CD3F11F642572466CEC17AFE8E38DD76A8398BE849AB21092693` |
| `windows/shell-prototype/adapters/services/Colours.qml` | `025BA4DF4C79FC0D42CFE389B06405CC31136980D0E4FDDDE5CB8E66D294AE23` |

Archive artifacts and SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| `result.json` | `B8E995BD55693A4AB486CF4671CCAFDA7804C6E0FB0AC6472030EAB086AB07EA` |
| `desktop-before.json` | `681DFF3D26F01F9FAFF6B6CC9E6E7D9625EB1C6EE38B0A725F1D18A47D34C314` |
| `desktop-after.json` | `C2203B175F17FBFA2A817D44240D9C5F08795B77C22414733A0DDDBC7A7A66E4` |
| `artifacts/bluetooth-disabled-screen0.png` | `8A5C6E70643D64F3EF5D998298E3F3B0E9D3DEA595071CAFA45C4683C36E0C8C` |
| `artifacts/bluetooth-readonly-screen0.png` | `0BBCA1F7C2591C272C82ED7A056956FD837CCB5D751E6F2BBBEAF9B225DF65FE` |
| `artifacts/bluetooth-disabled-screen1.png` | `ED1359D6016AB8A654AF11FB6ACF66F14CDFEB5494679B4A06C61126751DCFAC` |
| `artifacts/bluetooth-readonly-screen1.png` | `558A66559B508E74599A0248D0FAD4C42A203343D7599A093469C30DC3EF9391` |
| `artifacts/bluetooth-service.json` | `F702E1FE8C9149158DB21D10C07573B7E314C0DA16E41FA98C9FDDA463E6D85E` |
| `artifacts/media-service.json` | `BBED459665B45A9F26D6E0070984B834E3A28C58F4A2AFF8464E16C119594364` |
| `artifacts/battery-service.json` | `51006E6C9E44A0C96E0EF6C4CB3CF3358C177CC6E15C1D2E382997F6E3E0959C` |

## Commands

Native PowerShell from the repository root:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BluetoothService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BluetoothPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

The full harness also invokes the original M1 bar/session smoke. The shared
native build was not rebuilt or cleaned; all runs used fresh staging and
isolated profile directories named after their entry point.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen Bluetooth adapter | 182 assertions, 0 failed; 0 native imports, 0 hash mismatches, 0 QML diagnostics; `sourceDirty=false` | `artifacts/bluetooth-service.json` |
| Disabled UI, screen 0 at 150% | Pass; `status=disabled`, native loader inactive, no facade/status/popout item, no Bluetooth worker log | `artifacts/bluetooth-disabled-screen0.png` |
| Read-only UI, screen 0 at 150% | Pass; `status=on`, Intel adapter state `Enabled`, 0 devices, no discovery, all control hooks false, original status+popout loaded | `artifacts/bluetooth-readonly-screen0.png` |
| Disabled UI, screen 1 at 175% | Pass; same disabled policy | `artifacts/bluetooth-disabled-screen1.png` |
| Read-only UI, screen 1 at 175% | Pass; same read-only policy | `artifacts/bluetooth-readonly-screen1.png` |
| Original M1 regression | Pass | `result.json` record `m1-regression` |
| Media service regression | 148 assertions, 0 failed, exit 0, `sourceDirty=false` | `artifacts/media-service.json` |
| Battery service regression | 128 assertions, 0 failed, exit 0, `sourceDirty=false` | `artifacts/battery-service.json` |

The four native Bluetooth runs each completed in about 3.4 s and produced a PNG
and source/staged manifest. No run logged `WARN`, `ERROR`, `FAIL`, a missing
type, or a binding warning. The harness recorded `sourceDirty=false` at
`ddba8d12` with backend `14010429`.

### Native observation

The real adapter was `Intel(R) Wireless Bluetooth(R)`, native state `Enabled`
(`adapterState=1`). The paired-device model was empty in both read-only runs.
This is a healthy observation of the adapter with no paired devices; it is not a
claim that device enumeration, discovery or pairing work.

The disabled runs contain no `quickshell.windows.bluetooth` worker lines.
The read-only runs log the worker's `Using Bluetooth adapter ...` and `Started
the paired classic/LE device watcher` lines only, with `discovering=false`.

## Preserved state

`desktop-before.json` and `desktop-after.json` keep the same monitors, physical
work areas, taskbar flags/auto-hide, Explorer PID 9252 and KSG Shell PID 24108.
No pointer or keyboard input was synthesized, no system setting or privilege
changed, and no Bluetooth request was sent. The shared M1 regression and the
media/battery service fixtures also pass.

## Limits and unexercised behavior

- `Disabled` and `ReadOnly` were run natively. `Interactive` was **not** run.
- No radio toggle, discovery start/stop, connect, disconnect, pair, cancel,
  forget, or Windows Settings delegation was exercised. Those paths are
  fixture-validated only where noted below.
- A null adapter, blocked radio, radio off, unknown radio state, adapter
  removal/re-arrival, stale/removed devices, discovery expiry, connect/pair
  settling expiry, pairing cancellation, and unsupported setters are
  fixture-only. No real hardware or Windows denial produced them.
- Paired-device display, battery pass-through, discovery results and connection
  results are untested with real devices. The native runs observed zero paired
  devices.
- PIN/passkey pairing was not attempted. The backend rejects display/provide-PIN
  kinds and only logs the reason (`bt_worker.cpp` lines 257-290); the service
  therefore directs the user to the original "Open settings" button and never
  opens a credential UI or prompts automatically. That exact flow is untested.
- A permitted request is not a confirmed success. The backend has no per-command
  result; Windows refusal is visible only through later native state.

## Backend gaps recorded by this slice

- **No QML scan-completion state:** `WinBluetooth::isScanned()`/`scanned()` stay
  in C++ and `BluetoothQml` publishes only
  `defaultAdapter`/`adapters`/`devices`
  (`windows/deps/quickshell/src/windows/bluetooth/bluetooth.hpp` lines 32,
  67-77; `bluetooth.cpp` lines 37-41, 119-126). The service's 8 s
  first-observation bound is not proof of a completed hardware scan.
- **Unknown power folds into Disabled:** `stateForPower` maps `RadioPower::Off`
  and `RadioPower::Unknown` to `BluetoothAdapterState::Disabled`, and only
  `RadioState::Disabled` to `Blocked`
  (`windows/deps/quickshell/src/windows/bluetooth/adapter.cpp` lines 24-30,
  58-66). The `off` state therefore also covers unknown power.
- **Pairing kind/failure is not reported to QML:** rejections happen inside the
  worker's pairing callback and only log
  (`windows/deps/quickshell/src/windows/bluetooth/bt_worker.cpp` lines
  257-290). The QML device exposes `pairing` but not the failing kind.
- **Pairing has no native timeout:** `BluetoothDevice::pair()` starts the
  operation without a timer (`device.cpp` lines 132-146), so the adapter's
  20 s cancel is the only bound. Connect/disconnect states do have the native
  20 s settle timer (`device.cpp` lines 20, 104-108).
- **Unsupported setters warn only:** discoverable
  (`adapter.cpp` lines 87-94) and name/trusted/blocked/wake
  (`device.cpp` lines 168-188) change nothing, so the service refuses them and
  advertises no support.
- **No radio access result:** denied/unsupported radio access is logged in
  `bt_worker.cpp` lines 617-664; the QML service cannot distinguish a refusal
  from a pending request beyond the observed state.

No backend source, gitlink or `sources.lock.json` change is part of this slice.
