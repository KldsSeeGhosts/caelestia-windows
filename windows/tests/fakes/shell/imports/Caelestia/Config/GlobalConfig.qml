pragma Singleton
import QtQuick
QtObject {
    property QtObject services: QtObject { property bool smartScheme: true }
    property QtObject screenConfig: QtObject {
        property QtObject background: QtObject {
            property QtObject desktopClock: QtObject { property bool enabled: true }
        }
    }
    function forScreen(name): var { return screenConfig; }
}
