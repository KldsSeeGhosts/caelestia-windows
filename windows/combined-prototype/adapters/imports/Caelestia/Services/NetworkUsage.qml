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
    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: {
            if (SystemStats.networkDownloadBytesPerSec >= 0) {
                downloadBuffer.push(SystemStats.networkDownloadBytesPerSec);
                uploadBuffer.push(SystemStats.networkUploadBytesPerSec);
            }
        }
    }
}
