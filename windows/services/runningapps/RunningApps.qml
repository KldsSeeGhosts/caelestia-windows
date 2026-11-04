pragma Singleton

import QtQuick
import Quickshell.Windows
import qs.services

// Share the already opted-in Hypr observation. Native control still requires
// its existing dispatch opt-in; offscreen/read-only smoke cannot act on apps.
RunningAppsModel {
    id: root

    source: Hypr.toplevels.values
    actionsEnabled: Hypr.available && Hypr.dispatchEnabled

    // Foreground.foregroundChanged is the raw WinEvent handle, emitted for
    // every foreground change including the shell's own panels. Foreground's
    // address/title properties are the deduplicated facade and deliberately
    // keep the last application while a shell surface owns focus, so they
    // cannot decide whether an application is focused. The zero handle (no
    // window) and any handle that is not a tracked application leave this
    // empty. Windows handles fit well inside a JS number.
    readonly property Connections foregroundWatcher: Connections {
        target: Foreground

        function onForegroundChanged(hwnd): void {
            root.foregroundAddress = hwnd ? Number(hwnd).toString(16).toLowerCase() : "";
        }
    }
}
