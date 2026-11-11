pragma Singleton
import QtQuick

// Synthetic persisted state. The fixture asserts that the notification facade
// reads and writes this singleton; the plugin owns the actual file.
QtObject {
    property bool doNotDisturb: false
}
