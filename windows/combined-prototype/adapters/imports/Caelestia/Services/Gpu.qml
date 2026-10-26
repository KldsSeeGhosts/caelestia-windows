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
}
