pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils
import qs.modules.launcher.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/AppsPage.qml.
//
// Upstream's "Default applications" section edits `general.apps.terminal /
// audio / playback / explorer`, which are the Linux command lines Caelestia
// spawns itself. Windows owns default applications through its own per-protocol
// registrations, `general.apps.*` is documented as unused on this port
// (windows/docs/CONFIGURATION.md), and nothing in the Windows shell reads it,
// so keeping the four pickers would persist values with no effect. They are
// replaced by one honest row that opens Windows' default-apps page.
//
// "All apps" is upstream's library entry point. It reads Quickshell's
// DesktopEntries catalog, which the Windows launcher exposes behind the
// CAELESTIA_WINDOWS_APPS opt-in, so the row is disabled with the facade's own
// reason when that opt-in is off. Favourites and hidden apps still write
// `launcher.favouriteApps` / `launcher.hiddenApps`, which the Windows launcher
// reads.
PageBase {
    id: root

    title: Tr.tr("Apps")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Default applications
        SectionHeader {
            first: true
            text: Tr.tr("Default applications")
        }

        InfoRow {
            first: true
            last: true
            icon: "open_in_new"
            label: Tr.tr("Windows default apps")
            subtext: Tr.tr("Windows maps protocols and file types to apps itself")
            value: ""
        }

        // Library
        SectionHeader {
            text: Tr.trCtx("Library", "app library")
        }

        NavRow {
            first: true
            last: true
            icon: "apps"
            text: Tr.tr("All apps")
            subtext: Apps.enabled ? Tr.tr("Browse installed apps, set favourites and hidden") : Apps.reason
            disabled: !Apps.enabled
            onClicked: root.nState.openSubPage(1)
        }

        NavRow {
            first: true
            last: true
            icon: "settings"
            text: Tr.tr("Open Windows default apps")
            subtext: Tr.tr("Browser, mail, media player and file types")
            onClicked: Qt.openUrlExternally("ms-settings:defaultapps")
        }
    }
}
