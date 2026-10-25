import QtQuick
import qs.services
import qs.modules.bar.components.workspaces

// Loaded only after the observation backend is ready. The original
// SpecialWorkspaces component is used unmodified and receives the global
// focused monitor; the pinned backend never reports a special workspace, so
// this list stays empty and inactive.
Item {
    id: root

    implicitWidth: 64
    implicitHeight: 220

    SpecialWorkspaces {
        anchors.fill: parent
        monitor: Hypr.focusedMonitor
    }
}
