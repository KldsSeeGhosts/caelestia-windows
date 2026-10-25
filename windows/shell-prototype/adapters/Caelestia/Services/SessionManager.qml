pragma Singleton

import QtQuick
import Quickshell

// Caelestia.Services.SessionManager Windows boundary. The default is the
// previous unavailable behavior: no native Session singleton is resolved, every
// command is consumed and nothing is executed.
//
// CAELESTIA_WINDOWS_SESSION=1 loads the native facade for capability
// observation (including canHibernate). CAELESTIA_WINDOWS_SESSION_ACTIONS=1
// additionally permits allowlisted dispatch; it is independent so observation
// alone can never invoke lock/suspend/etc. Smoke runs force both off.
//
// The service always consumes commands, including unknown ones, so the original
// components' detached fallback cannot run. allowDetachedFallback is the
// localized UI hook: upstream native SessionManager lacks the property, so Linux
// keeps its fallback; this Windows adapter sets it false.
SessionService {
    id: root

    enabled: Quickshell.env("CAELESTIA_WINDOWS_SESSION") === "1"
    actionsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_SESSION_ACTIONS") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error
        ? "The Windows session backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requests the native facade.
    readonly property bool nativeRequested: nativeLoader.active

    // Localized original-UI hooks. Upstream Linux SessionManager does not
    // define these properties, so the Windows values do not change Linux
    // defaults.
    readonly property bool sessionActionGating: true
    readonly property bool allowDetachedFallback: false

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeSessionBackend.qml") : ""
    }
}
