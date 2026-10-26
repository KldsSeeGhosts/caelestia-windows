pragma Singleton
import QtQuick
import Quickshell.Windows
QtObject {
    readonly property string name: SystemMonitor.cpuName
    readonly property real percentage: SystemMonitor.cpuUsage
    readonly property real temperature: SystemMonitor.cpuTemperature
}
