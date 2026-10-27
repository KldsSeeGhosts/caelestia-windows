import QtQuick
import Caelestia.Windows

// Loaded only while windows.focusFollowsMouse.enabled is true. The native
// object is loader-owned: destroying this wrapper (option off, clean shell
// exit) destroys it and restores the values captured before the first write.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    WindowsFocusFollowsMouse {
        id: nativeService
    }

    readonly property var nativeInstance: nativeService

    function apply(enabled, delay, raise): bool {
        return nativeService.apply(enabled, delay, raise);
    }

    function restore(): void {
        nativeService.restore();
    }
}
