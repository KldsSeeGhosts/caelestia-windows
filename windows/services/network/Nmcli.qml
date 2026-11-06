pragma Singleton

import QtQuick
import Quickshell

// Windows stand-in for services/Nmcli.qml. The original network popout imports
// qs.services and keeps its Nmcli references; this singleton is staged at
// services/Nmcli.qml and preserves the observation and command names that
// component uses. It projects the bounded native state through NetworkService
// and adds no nmcli process, monitor command, callback timer or credential
// path.
//
// The typed AccessPoint/EthernetDevice projections live here because the
// original popout declares Nmcli.AccessPoint and Nmcli.EthernetDevice. The
// pure state object stays free of Quickshell and of these display types.
NetworkService {
    id: root

    // These flags belong only to the child shell process. Importing Nmcli with
    // network disabled never resolves the native Network singleton or starts
    // WLAN observation. Controls are a separate opt-in: observation without
    // them never sends a radio, connect, disconnect or forget request.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_NETWORK") === "1"
    controlsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_NETWORK_CONTROLS") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows network backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requests the native facade. The facade itself constructs Network.
    readonly property bool nativeRequested: nativeLoader.active

    // Typed Wi-Fi boundary for the original UI. The native model only supplies
    // these fields (network_wifi_item.hpp:15-21); hasProfile is the Windows
    // profile flag used to avoid a credential path for unknown networks.
    component AccessPoint: QtObject {
        id: point

        required property var raw

        readonly property string ssid: typeof raw?.ssid === "string" ? raw.ssid : ""
        readonly property string bssid: typeof raw?.bssid === "string" ? raw.bssid : ""
        readonly property int strength: Number.isFinite(raw?.strength)
            ? Math.max(0, Math.min(100, Math.round(raw.strength))) : 0
        readonly property int frequency: Number.isFinite(raw?.frequency)
            ? Math.max(0, Math.round(raw.frequency)) : 0
        readonly property bool active: raw?.active === true
        readonly property string security: typeof raw?.security === "string" ? raw.security : ""
        readonly property bool isSecure: security.length > 0
        readonly property bool hasProfile: raw?.hasProfile === true
    }

    // Typed wired boundary. The pinned backend reports only whether a wired
    // connection is up, so address, speed, usage and saved-connection details
    // stay explicitly empty instead of being approximated.
    component EthernetDevice: QtObject {
        id: device

        required property var raw

        readonly property string iface: typeof raw?.iface === "string" ? raw.iface : ""
        readonly property string type: typeof raw?.type === "string" ? raw.type : ""
        readonly property string state: typeof raw?.state === "string" ? raw.state : ""
        readonly property string connection: typeof raw?.connection === "string" ? raw.connection : ""
        readonly property bool connected: raw?.connected === true
        readonly property string ipAddress: ""
        readonly property string gateway: ""
        readonly property var dns: []
        readonly property string subnet: ""
        readonly property string macAddress: ""
        readonly property string speed: ""
    }

    readonly property Component accessPointComponent: Component {
        AccessPoint {}
    }
    readonly property Component ethernetDeviceComponent: Component {
        EthernetDevice {}
    }

    // Reuse typed AccessPoint wrappers across polls. NetworkService rebuilds
    // networkSources from each refreshed native list, but the BSSID (plus SSID)
    // is stable, so update the existing wrapper's raw object in place and only
    // create/destroy wrappers when the visible set changes.
    property var _networkWrappers: ({})
    property var _networks: []

    readonly property var networks: root._networks

    function networkKey(raw): string {
        const bssid = typeof raw?.bssid === "string" ? raw.bssid.trim() : "";
        const ssid = typeof raw?.ssid === "string" ? raw.ssid : "";
        return bssid.length > 0 ? bssid + "\u0000" + ssid : "ssid:" + ssid;
    }

    function syncNetworks(): void {
        const sources = root.networkSources;
        const previous = root._networkWrappers;
        const wrappers = ({});
        const points = [];
        const stale = [];
        let changed = sources.length !== root._networks.length;

        for (let i = 0; i < sources.length; i++) {
            const raw = sources[i];
            const key = root.networkKey(raw);
            let point = previous[key];
            if (!point) {
                point = root.accessPointComponent.createObject(null, {
                    raw: raw
                });
                changed = true;
            } else if (point.raw !== raw) {
                point.raw = raw;
            }
            wrappers[key] = point;
            points.push(point);
            if (root._networks[i] !== point)
                changed = true;
        }

        for (const key in previous)
            if (!wrappers[key])
                stale.push(previous[key]);

        root._networkWrappers = wrappers;
        if (changed)
            root._networks = points;
        for (const point of stale)
            point.destroy();
    }

    onNetworkSourcesChanged: root.syncNetworks()
    // A completed refresh publishes its generation only after the typed wrappers
    // are rebuilt, so a consumer that reads `networks`/`findNetwork` from the
    // change handler already sees that refresh's access points.
    snapshotReconciler: function() {
        root.syncNetworks();
        root.publishSnapshot();
    }
    Component.onCompleted: {
        root.syncNetworks();
        root.syncEthernet();
    }

    readonly property AccessPoint active: root.networks.find(point => point.active) ?? null

    // The wired list uses the same keyed reuse as the Wi-Fi list: the old
    // binding created a parentless EthernetDevice on every re-evaluation and
    // never destroyed it. The synthesized wired record carries no interface
    // name yet, so its type/state/connection identify it until the backend
    // reports one.
    property var _ethernetWrappers: ({})
    property var _ethernetDevices: []

    readonly property var ethernetDevices: root._ethernetDevices

    function ethernetKey(raw): string {
        const iface = typeof raw?.iface === "string" ? raw.iface.trim() : "";
        if (iface.length > 0)
            return iface;
        const type = typeof raw?.type === "string" ? raw.type : "";
        const state = typeof raw?.state === "string" ? raw.state : "";
        const connection = typeof raw?.connection === "string" ? raw.connection : "";
        return "device:" + type + "\u0000" + state + "\u0000" + connection;
    }

    function syncEthernet(): void {
        const sources = root.ethernetSources;
        const previous = root._ethernetWrappers;
        const wrappers = ({});
        const devices = [];
        const stale = [];
        // Two wired entries can share an interface name, and the synthesized
        // record has no interface at all, so the fallback key can repeat too.
        // Pair each key with its occurrence within this sync, or the second
        // entry would alias the first one's wrapper and stay untracked. The
        // pair is serialized as a tuple, so no interface name (even one that
        // looks like a suffixed key) can collide with another entry.
        const seen = new Map();
        let changed = sources.length !== root._ethernetDevices.length;

        for (let i = 0; i < sources.length; i++) {
            const raw = sources[i];
            const base = root.ethernetKey(raw);
            const occurrence = seen.get(base) ?? 0;
            seen.set(base, occurrence + 1);
            // The ordinary single-entry case is occurrence 0 and still
            // reuses its wrapper across syncs.
            const key = JSON.stringify([base, occurrence]);
            let device = previous[key];
            if (!device) {
                device = root.ethernetDeviceComponent.createObject(null, {
                    raw: raw
                });
                changed = true;
            } else if (device.raw !== raw) {
                device.raw = raw;
            }
            wrappers[key] = device;
            devices.push(device);
            if (root._ethernetDevices[i] !== device)
                changed = true;
        }

        for (const key in previous)
            if (!wrappers[key])
                stale.push(previous[key]);

        root._ethernetWrappers = wrappers;
        if (changed)
            root._ethernetDevices = devices;
        for (const device of stale)
            device.destroy();
    }

    onEthernetSourcesChanged: root.syncEthernet()

    readonly property EthernetDevice activeEthernet: root.ethernetDevices.find(device => device.connected) ?? null

    // Upstream names consumed by the original popout and by its helpers.
    // scanning and connecting are inherited from NetworkService.
    readonly property bool wifiEnabled: root.radioOn
    readonly property bool hasAvailableEthernet: root.ethernetConnected

    function enableWifi(enabled): void {
        root.requestRadio(enabled);
    }

    // Upstream returns a typed access point here. The raw projection must not
    // leak because consumers (for example saved-network pages) read isSecure.
    function findNetwork(ssid): var {
        if (typeof ssid !== "string" || ssid.length === 0)
            return null;
        return root.networks.find(point => point.ssid === ssid) ?? null;
    }

    function rescanWifi(): void {
        root.requestScan();
    }

    function connectToAccessPoint(point): void {
        root.requestConnect(point?.raw ?? point);
    }

    function disconnectFromNetwork(): void {
        root.requestDisconnect();
    }

    function forgetNetwork(ssid): void {
        root.requestForget(ssid);
    }

    // The pinned backend has no wired control, address, speed or usage API.
    // These keep the original popout's call sites loadable and report the
    // unsupported action instead of pretending to act.
    function connectEthernet(connection, interfaceName, callback): void {
        root.reportEthernetUnavailable();
    }

    function disconnectEthernet(connection, callback): void {
        root.reportEthernetUnavailable();
    }

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeNetworkBackend.qml") : ""
    }
}
