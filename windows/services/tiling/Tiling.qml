pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.services

// Windows stand-in for a services/Tiling.qml, staged at services/Tiling.qml
// by the tiling and combined prototypes. It keeps the pure TilingService policy,
// watches GlobalConfig.windows.tiling, and owns the native wrapper Loader and bridge to
// Caelestia's original toast surface. The Quickshell.Windows import lives
// only in NativeTilingBackend.qml, which this facade loads through a Loader
// only for mode observe or interactive; `off` resolves no native type and
// constructs nothing.
//
// Environment overrides (explicit launcher switches take precedence):
//   CAELESTIA_WINDOWS_TILING=off|observe|interactive (default off)
//   CAELESTIA_WINDOWS_TILING_INCLUDED  semicolon-separated wildcard allowlist
//   CAELESTIA_WINDOWS_TILING_EXCLUDED  semicolon-separated wildcard denylist
// Interactive may enable the tiler only with a non-empty allowlist on a
// backend that supports it, and never during smoke. Tiling is meaningful
// with CAELESTIA_WINDOWS_HYPR=1 observation (failure records resolve window
// names through its toplevels); it is not hard-required and the generic
// "a window" wording is used without it.
TilingService {
    id: root

    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error
        ? "The Windows tiling backend component failed to load." : ""

    // Upstream daemons localize their copy through Tr; the fixture keeps the
    // identity default. Names are appended outside the translated fragment.
    tr: text => Tr.tr(text)

    // Failure addresses are lowercase hex without 0x on both surfaces
    // (hyprland_toplevel.cpp:218-219), so the comparison is direct.
    resolveToplevel: address => {
        const values = Hypr.toplevels?.values;
        if (!Array.isArray(values))
            return null;
        const normalized = String(address ?? "").toLowerCase();
        const match = values.find(t => typeof t?.address === "string"
            && t.address.toLowerCase() === normalized);
        if (!match)
            return null;
        return {
            appClass: typeof match.lastIpcObject?.class === "string"
                ? match.lastIpcObject.class : "",
            title: typeof match.title === "string" ? match.title : ""
        };
    }

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.nativeRequested
        source: root.nativeRequested ? Qt.resolvedUrl("NativeTilingBackend.qml") : ""
    }

    readonly property Connections _backendSignals: Connections {
        target: nativeLoader.item

        function onEnableRefused(reason): void {
            root.handleEnableRefused(reason);
        }
        function onWindowTilingFailed(address, reason): void {
            root.handleWindowTilingFailed(address, reason);
        }
    }

    property bool statusLogged: false
    property bool configReady: false
    property string lastConfiguration: ""

    // ConfigRoot owns profile watching, parsing and persistence. Use the
    // global Windows extension; monitor admission belongs to the native
    // tiler's screen rules rather than Caelestia's visual screen overlays.
    readonly property var profileSettings: GlobalConfig.windows?.tiling ?? ({})
    onProfileSettingsChanged: if (root.configReady) root.applyConfiguration(root.profileSettings)

    function applyConfiguration(settings): void {
        // Materialize QVariantMap/List wrappers as ordinary JS containers so
        // array validation and monitor-key enumeration use the same semantics
        // as the standalone policy fixture.
        settings = JSON.parse(JSON.stringify(settings));
        const overrides = {};
        for (const field of ["mode", "included", "excluded"]) {
            const variable = field === "mode" ? "CAELESTIA_WINDOWS_TILING"
                : "CAELESTIA_WINDOWS_TILING_" + field.toUpperCase();
            const value = Quickshell.env(variable);
            // Quickshell.env returns null for absent variables. A companion
            // marker allows launcher switches to deliberately clear lists.
            if ((typeof value === "string" && value !== "")
                    || Quickshell.env(variable + "_OVERRIDE") === "1")
                overrides[field] = value ?? "";
        }
        const signature = JSON.stringify([settings, overrides]);
        if (signature === root.lastConfiguration)
            return;
        root.lastConfiguration = signature;
        root.configureProfile(settings, overrides,
            Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1");
        console.log("CAELESTIA_TILING_CONFIG tiling=" + root.mode
            + " gapsIn=" + root.gapsIn + " gapsOut=" + root.gapsOut
            + " status=" + root.status);
    }

    Component.onCompleted: {
        // Connected first: configure() activates the Loader, and a backend
        // attached during it can already produce a refusal toast.
        root.toastDecision.connect((title, message, icon, type) => {
            Toaster.toast(title, message, icon, type === 3 ? Toast.Error : Toast.Warning);
        });
        root.configReady = true;
        root.applyConfiguration(root.profileSettings);
    }

    // Printed once so the launch log proves which opt-ins the child process
    // observed and what the startup policy decided.
    function logStartupStatus(): void {
        if (root.statusLogged)
            return;
        root.statusLogged = true;
        console.log("CAELESTIA_TILING_STATUS tiling=" + root.mode
            + " included=" + root.includedPatterns.length
            + " excluded=" + root.excludedPatterns.length
            + " gapsIn=" + root.gapsIn + " gapsOut=" + root.gapsOut
            + " status=" + root.status);
    }
}
