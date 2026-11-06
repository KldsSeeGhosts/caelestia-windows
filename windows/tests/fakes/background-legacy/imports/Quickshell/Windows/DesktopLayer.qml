pragma Singleton
import QtQuick
QtObject {
    // Deliberately lacks the optional underlay/refusal properties.
    property bool enabled: false
    property bool active: false
    property var aboveIcons: []
    signal wallpaperChanged()
}
