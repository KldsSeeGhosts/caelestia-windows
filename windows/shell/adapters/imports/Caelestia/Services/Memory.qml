pragma Singleton
import QtQuick
import Quickshell.Windows
QtObject {
    readonly property real total: SystemMonitor.memoryTotal / 1024
    readonly property real used: SystemMonitor.memoryUsed / 1024
    readonly property real percentage: total > 0 ? used / total : 0
}
