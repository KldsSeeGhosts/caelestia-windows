pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Windows
import Caelestia
Singleton {
    id: root
    // Keep the last native sample through shutdown. Direct bindings can run
    // after the C++ singleton has been destroyed while two dashboards unload.
    property real downloadSpeed: -1
    property real uploadSpeed: -1
    property real downloadTotal: 0
    property real uploadTotal: 0
    function refresh(): void {
        downloadSpeed = SystemStats.networkDownloadBytesPerSec;
        uploadSpeed = SystemStats.networkUploadBytesPerSec;
        downloadTotal = SystemStats.networkDownloadedBytes;
        uploadTotal = SystemStats.networkUploadedBytes;
    }
    Component.onCompleted: refresh()
    Connections {
        target: SystemStats
        function onNetworkDownloadBytesPerSecChanged(): void { root.refresh(); }
        function onNetworkUploadBytesPerSecChanged(): void { root.refresh(); }
        function onNetworkDownloadedBytesChanged(): void { root.refresh(); }
        function onNetworkUploadedBytesChanged(): void { root.refresh(); }
    }
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
