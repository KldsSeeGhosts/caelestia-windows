# Windows network prototype

ERM-500's bounded M2 network slice projects the pinned backend's
`Quickshell.Windows.Network` connectivity/WLAN state through a default-off
adapter and loads the **original** Caelestia network popout in a separate
native window. No nmcli process graph, callback timer, credential prompt or
Ethernet configuration UI is reimplemented.

## Scope and the original component

The staged surface is
[`modules/bar/popouts/Network.qml`](../../modules/bar/popouts/Network.qml) plus
its original `PopoutState`, `StyledSwitch`, `CircularIndicator`,
`CircularProgress`, `Icons` and `NetworkConnection` dependencies. The host
places the popout in a window of at most 520x680 logical pixels, inset 80 from
the chosen screen. Escape closes an interactive run. The header reuses the
original bar status expression for the network entry
(`modules/bar/components/StatusIcons.qml`): `cable` when wired is connected, the
original `Icons.getNetworkIcon()` signal glyph when a Wi-Fi access point is
active, otherwise `wifi_off`.

The original popout owns its typography, icons, sorting, entry motion,
scan spinner and Ethernet rows. Windows adaptation is limited to hooks, all
defaulting to upstream behavior:

- `controlsEnabled` gates the radio toggle, access-point connect/disconnect and
  the Ethernet row action. Upstream stays interactive.
- `nativeConnect` routes the access-point action to the host facade instead of
  `NetworkConnection.handleConnect()`. The `NetworkConnection` singleton is
  still staged unchanged because the original component references it
  statically, but the Windows path never calls it.
- `nativeConnectingSsid` lets the facade's observed `wifiConnectingSsid` drive
  the original row spinner; an empty value preserves the component's own
  `connectingToSsid` marker.
- `statusText` renders command/state feedback in the popout's existing small
  text style. It is empty upstream, so Linux renders no extra line.
- `ethernetControlAvailable` disables the original Ethernet action. The pinned
  backend has no wired control.

The original password popout (`WirelessPassword.qml`) is **not** staged. This
slice has no password argument, field, store or log path. A secured network
with no saved Windows profile is refused with a short message that points to
Windows Settings; the host does not open it automatically.

The popout's `view` uses the original routing expression from
[`Content.qml`](../../modules/bar/popouts/Content.qml): Ethernet when a wired
link is up, otherwise wireless. On a desktop with an active Ethernet link the
native smoke therefore shows the original Ethernet section; the Wi-Fi section
and its denied/offline states are fixture-validated unless the machine is
running on Wi-Fi.

## Service states and the typed boundary

[`NetworkService.qml`](../services/network/NetworkService.qml) imports no
Quickshell or native module and runs no process. The singleton wrapper
[`Nmcli.qml`](../services/network/Nmcli.qml) is staged at `services/Nmcli.qml`,
so the original popout's `import qs.services` and `Nmcli.*` references resolve
without an upstream import change. The wrapper owns the typed
`Nmcli.AccessPoint` and `Nmcli.EthernetDevice` display types, the environment
opt-ins and the native loader; the state object owns lifecycle, list policy,
membership guards and command results.

States:

| state | meaning |
| --- | --- |
| `disabled` | observation opt-in absent; no native loader, facade or popout |
| `initializing` | enabled, waiting for the bounded first WLAN observation |
| `no-adapter` | initialized without a reported Wi-Fi adapter |
| `location-denied` | Windows location permission denied; list and connection hidden |
| `radio-off` | adapter present, Wi-Fi radio off |
| `connecting` | a connection request is in flight |
| `connected` | a Wi-Fi SSID is associated (optionally without internet) |
| `disconnected` | radio on, no associated network |
| `unavailable` | the backend component failed to load |

The pinned backend has no initialization flag or error string. Construction
starts connectivity/WLAN observation after the first frame and a successful
WLAN open performs one nearby-network query even while the list is hidden
(`network.cpp:15-25`, `network_wifi.cpp:168-194`). The wrapper therefore
supplies a bounded adapter flag: `initialized` becomes true on the first WLAN
observation or when a one-shot four-second settle window expires. The expiry
reports absence, not proof of "no adapter": a WLAN service failure also leaves
`wifiAdapterPresent=false` and only logs at debug level
(`network_wifi.cpp:169-173`). Loading the popout and observation are separate:
disabled mode constructs neither.

The access-point list is hidden (`listHidden`) while the adapter, radio or
location permission cannot support a truthful query. A denied
current-connection query returns early and can leave a previous SSID in native
state (`network_wifi.cpp:369-372`), so the adapter reports no active SSID while
location is denied rather than repeating an unverifiable value. SSID entries
must be objects with a non-empty string SSID.

Scan policy: the adapter never asks for a scan or a list refresh while the list
is hidden or the service is unavailable. `setListVisible(true)` is the only path
that asks the backend to refresh and start its eight-second scan timer
(`network.cpp:71-82`); hiding, radio loss or location denial stops the timer.
`-Smoke` runs never set list visibility, so they observe the backend's single
startup query and request no scan.

Command results are explicit and never optimistic:

| command | evidence |
| --- | --- |
| connect | `wifiConnectResult(ssid, success, reason)`; only a result matching this adapter's pending request is accepted |
| radio | no native result; reported as requested/unverified (`network_wifi.cpp:232-258`) |
| disconnect | no native result; requested/unverified (`network_wifi.cpp:451-454`) |
| forget | no native result; requested/unverified (`network_wifi.cpp:456-460`) |
| scan | no per-scan result; `wifiScanning` is the only evidence (`network_wifi.cpp:260-271`) |

`requestConnect()` validates state, membership, the active guard and the
credential boundary before calling the backend. That matters because
`connectToNetwork()` trusts its caller: an unknown SSID is treated as an open
network and a profile may be written (`network.cpp:41-54`,
`network_wifi.cpp:409-428`). `requestForget()` also requires a visible access
point with a saved profile, because the backend otherwise deletes a profile
named by the raw SSID. A foreign or removed access point is refused as stale
and sends nothing.

Ethernet: the pinned backend exposes only `ethernetConnected` and `hasInternet`.
The typed `EthernetDevice` therefore reports `state="connected"` with unknown
interface/connection names and empty address, gateway, DNS, subnet, MAC and
speed fields. There is no wired adapter list, control, speed/usage telemetry or
saved-connection detail in this slice.

## Opt-ins and launch

Both opt-ins are child-process environment variables; the launcher sets them
explicitly so inherited flags cannot enable network in the M1 profile.

- `CAELESTIA_WINDOWS_NETWORK=1` observes adapter/radio/connection/list state and
  constructs the native `Network` singleton after the first frame.
- `CAELESTIA_WINDOWS_NETWORK_CONTROLS=1` additionally permits explicit radio,
  connect, disconnect and forget requests. It is only set for a non-smoke
  `Interactive` run.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Network -NetworkMode ReadOnly -Wait
```

`-Network` selects this entry point. `Disabled` is the default and never loads
`NativeNetworkBackend.qml` or the original popout. `ReadOnly` observes and keeps
every control disabled. `Interactive` also enables the control hook for
explicit user interaction; it is not validated by this slice and sends no
automatic request. Every `-Smoke` run is read-only and no-scan regardless of
the requested mode. The M1 entry point and the audio/battery/media prototypes
keep their own profiles and flags.

The `Nmcli` facade exposes `wifiEnabled`, `networks`, `active`,
`ethernetDevices`, `activeEthernet`, `scanning`, `connecting`, `connectingSsid`,
`enableWifi()`, `rescanWifi()`, `connectToAccessPoint()`,
`disconnectFromNetwork()` and `forgetNetwork()`. It does not expose the upstream
nmcli process helpers, saved-connection detail, IPv4 configuration,
autoconnect, hidden-network creation, Ethernet configuration or any password
argument. `connectEthernet()`/`disconnectEthernet()` report the unsupported
action instead of acting.

## Validation

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-NetworkService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-NetworkPrototype.ps1 `
    -QtPrefix $qtPrefix
```

`Test-NetworkService.ps1` stages only the adapter and fixture into Qt's
offscreen `qml.exe`. It rejects native imports, staging hash mismatches and QML
diagnostics. Its injected assertions cover:

- safe disabled construction and the absence of password/process members;
- disabled and initializing refusals that send nothing;
- no-adapter, radio-off, location-denied (hidden list and connection state),
  disconnected, limited, connecting, connected and unavailable transitions;
- list projection (order, invalid entries), membership and saved-profile guards;
- scan bounding while hidden and on visibility, radio and location changes;
- connect success/failure results, mismatched/external result rejection, the
  busy and active-network guards and the no-password credential boundary;
- stale/removed access points, unverified radio/disconnect/forget requests,
  controls-off refusal and malformed backend shapes;
- the Ethernet boundary and disable-time cleanup.

`Test-NetworkPrototype.ps1` runs the fixture, then disabled/read-only smoke on
every measured connected screen, then the original M1 bar/session regression.
Each smoke asserts the disabled mode leaves the native loader and original
popout inactive; an enabled run loads the original popout with controls and the
Ethernet action disabled, requests no scan and sends no command; each run
records source and staged hashes, initial/final state, logs and a PNG. The
desktop identity gate ignores otherwise-unrelated concurrent `qs` prototype
processes (other agents may run bounded smokes at the same time); every
harness-owned run is separately required to exit cleanly with no diagnostics.

Raw results are under `windows/.local/build/network-validation-<timestamp>/`.

## Limits

- Native initialization/radio/adapter/connection/list observation is exercised
  on this workstation's hardware, which has an active Ethernet link, a present
  Wi-Fi adapter and radio on with no associated network and no visible access
  points. Connected Wi-Fi, access-point rows, connect results and location
  denial are fixture-validated only. Real access-point connect/disconnect/
  forget, radio toggling and denial/recovery are **not** exercised by this
  slice and must not be claimed.
- The four-second settle flag is an adapter heuristic, not a backend capability;
  a WLAN service failure is presented as `no-adapter`.
- A refused radio write only warns and may open Windows Settings; this slice
  reports the request as unverified and performs no retry or privilege change.
- Startup performs one nearby-network query even when the list is hidden; that
  backend behavior is documented rather than worked around.
- The original password dialog, saved-network details, IPv4 configuration,
  hidden-network creation, autoconnect, Ethernet speed/usage and wired control
  remain unavailable.
- The fixed-palette prototype adapter gained `m3outline`,
  `m3surfaceContainerHighest` and an opaque `layer()` passthrough so the
  original `StyledSwitch` renders without theme access. No upstream file gained
  a visual approximation.
