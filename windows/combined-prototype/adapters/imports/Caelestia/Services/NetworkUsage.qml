pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Windows
import Caelestia
Singleton {
    readonly property real downloadSpeed: SystemStats.networkDownloadBytesPerSec
    readonly property real uploadSpeed: SystemStats.networkUploadBytesPerSec
    readonly property real downloadTotal: SystemStats.networkDownloadedBytes
    readonly property real uploadTotal: SystemStats.networkUploadedBytes
    readonly property int historyLength: 30
    readonly property CircularBuffer downloadBuffer: CircularBuffer { capacity: 30 }
    readonly property CircularBuffer uploadBuffer: CircularBuffer { capacity: 30 }
    Connections {
        target: SystemStats
        function onActiveChanged(): void {
            if (!SystemStats.active) {
                // A hidden interval is not a continuous two-second graph sample.
                downloadBuffer.clear();
                uploadBuffer.clear();
            }
        }
    }
    Timer {
        interval: 2000
        // Do not append stale samples while the dashboard's native sampler sleeps.
        running: SystemStats.active
        repeat: true
        onTriggered: {
            if (SystemStats.networkDownloadBytesPerSec >= 0) {
                downloadBuffer.push(SystemStats.networkDownloadBytesPerSec);
                uploadBuffer.push(SystemStats.networkUploadBytesPerSec);
            }
        }
    }
}
