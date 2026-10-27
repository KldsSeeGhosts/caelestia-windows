import QtQuick
import Quickshell
import Caelestia.Windows

// Loaded only while windows.focusFollowsMouse.enabled is true. The native
// object is loader-owned, but the applied values are owned process-wide by the
// plugin: a replacement generation created by a reload shares the old
// generation's baseline, and the old destructor does not restore it while the
// replacement is live.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    readonly property string recoveryDirectory: Quickshell.env("CAELESTIA_RUNTIME_DIR") || ""

    WindowsFocusFollowsMouse {
        id: nativeService
        recoveryDirectory: root.recoveryDirectory
    }

    readonly property var nativeInstance: nativeService

    function apply(enabled, delay, raise): bool {
        return nativeService.apply(enabled, delay, raise);
    }

    function restore(): void {
        nativeService.restore();
    }
}
