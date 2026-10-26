pragma Singleton
import QtQuick
import Quickshell.Windows
QtObject {
    readonly property var disks: Array.from(SystemMonitor.disks).reduce((all, d) => all.concat(Array.from(d.volumes ?? [])), []).map(v => ({
        mount: v.mount, total: v.totalBytes / 1024, used: v.usedBytes / 1024,
        perc: v.totalBytes > 0 ? v.usedBytes / v.totalBytes : 0
    }))
    property var manualPrimaryDisk: null
    readonly property var primaryDisk: disks.find(d => d.mount === manualPrimaryDisk?.mount) ?? disks[0] ?? null
    readonly property real percentage: primaryDisk?.perc ?? 0
}
