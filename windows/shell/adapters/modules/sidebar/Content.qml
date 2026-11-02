import QtQuick
import qs.services

// Reuse the upstream layout and the same status row as the bounded prototype.
SidebarContent {
    mirrorControl: Notifs.mirrorControlEnabled ? Notifs : null
}
