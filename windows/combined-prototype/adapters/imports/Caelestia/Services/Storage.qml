pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Windows
QtObject {
    id: root

    // One long-lived object per mount, updated in place. The dashboard builds
    // its drive menu from this list and matches the selection by identity, so
    // the list changes only when a drive appears or disappears, not on every
    // free-space change.
    component Disk: QtObject {
        property string mount
        property real total
        property real used
        readonly property real perc: total > 0 ? used / total : 0
    }
    readonly property Component diskComponent: Component { Disk {} }

    // A drive that misses a refresh is kept for this many more refreshes, so
    // one failed native query does not empty the list or reorder the primary.
    readonly property int missedRefreshesAllowed: 2
    property var disks: []
    property var manualPrimaryDisk: null
    readonly property string systemMount: (Quickshell.env("SystemDrive") || "C:").toUpperCase() + "\\"
    readonly property var primaryDisk: disks.find(d => d === manualPrimaryDisk)
        ?? disks.find(d => d.mount === manualPrimaryDisk?.mount)
        ?? disks.find(d => d.mount.toUpperCase() === systemMount)
        ?? disks[0] ?? null
    readonly property real percentage: primaryDisk?.perc ?? 0

    property var _known: ({})
    property var _missed: ({})

    function sync(): void {
        const seen = {};
        for (const physical of Array.from(SystemMonitor.disks)) {
            for (const v of Array.from(physical.volumes ?? [])) {
                seen[v.mount] = true;
                let disk = _known[v.mount];
                if (!disk) {
                    disk = diskComponent.createObject(root, { mount: v.mount });
                    _known[v.mount] = disk;
                }
                disk.total = v.totalBytes / 1024;
                disk.used = v.usedBytes / 1024;
                _missed[v.mount] = 0;
            }
        }

        let changed = false;
        for (const mount of Object.keys(_known)) {
            if (seen[mount]) continue;
            _missed[mount] = (_missed[mount] ?? 0) + 1;
            if (_missed[mount] > missedRefreshesAllowed) {
                if (manualPrimaryDisk === _known[mount]) manualPrimaryDisk = null;
                _known[mount].destroy();
                delete _known[mount];
                delete _missed[mount];
                changed = true;
            }
        }

        const mounts = Object.keys(_known).sort();
        if (changed || mounts.length !== disks.length || mounts.some((m, i) => disks[i]?.mount !== m)) {
            disks = mounts.map(m => _known[m]);
        }
    }

    // SystemMonitor replaces its disk list only when the content changes, and
    // it samples only while a dashboard is visible.
    readonly property Connections _monitor: Connections {
        target: SystemMonitor
        function onDisksChanged(): void { root.sync(); }
    }
    Component.onCompleted: sync()
}
