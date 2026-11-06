pragma Singleton
import QtQuick
QtObject {
    property var windows: ({clipboard: {enabled: false}})
    property var notifs: ({defaultExpireTimeout: 5000, fullscreenExpireTimeout: 2000, expire: false, fullscreen: 0})
}
