pragma Singleton
import QtQuick
import Quickshell.Windows
QtObject {
    readonly property var gpu: SystemMonitor.gpus[0] ?? null
    readonly property int type: gpu ? 2 : 3
    readonly property string name: gpu?.name ?? "Unavailable"
    readonly property bool detecting: !SystemMonitor.ready
    readonly property real percentage: gpu?.usage ?? NaN
    readonly property real temperature: gpu?.temperature ?? NaN
    // Dedicated video memory in bytes, from the same adapter as name and usage.
    // The backend's separate sharedUsed counter is never added to it.
    readonly property real vramUsed: gpu?.vramUsed ?? NaN
    readonly property real vramTotal: gpu?.vramTotal ?? NaN
}
