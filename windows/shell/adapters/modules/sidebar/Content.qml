import QtQuick
import qs.services

// Reuse the upstream layout and the same status row as the bounded prototype.
// The row is shown whenever there is a status to report (including a failed
// session-bus lock); its own actions remain gated by mirrorStaged.
SidebarContent {
    mirrorControl: Notifs.mirrorControlVisible ? Notifs : null
}
