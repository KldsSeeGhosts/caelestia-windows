import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components.controls
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/services/NotificationsPage.qml.
//
// The notification, fullscreen, timeout and visible-toast controls are kept:
// the Windows notification service reads each one. The "Toast events" section
// is removed because none of its flags has a producer in the staged Windows
// services (there is no battery/audio/keyboard-layout/VPN/now-playing event
// path, and the Windows Notifs facade never reads dndChanged). Leaving the
// toggles visible would present saved values as live controls.
PageBase {
    id: root

    // Notification fullscreen visibility, ordered to match config::NotifsFullscreen (On, Off)
    readonly property list<MenuItem> notifFullscreenItems: [
        MenuItem {
            text: Tr.trCtx("On", "show notifications over fullscreen apps")
            icon: "notifications"
        },
        MenuItem {
            text: Tr.trCtx("Off", "show notifications over fullscreen apps")
            icon: "notifications_off"
        }
    ]

    // Toast fullscreen visibility, mapped to GlobalConfig.utilities.toasts.fullscreen
    readonly property list<MenuItem> toastFullscreenItems: [
        MenuItem {
            text: Tr.trCtx("Off", "show toasts over fullscreen apps")
            icon: "notifications_off"
        },
        MenuItem {
            text: Tr.trCtx("Important", "show toasts over fullscreen apps: important ones only")
            icon: "priority_high"
        },
        MenuItem {
            text: Tr.trCtx("On", "show toasts over fullscreen apps")
            icon: "notifications"
        }
    ]
    readonly property list<string> toastFullscreenValues: ["off", "important", "all"]

    title: Tr.tr("Notifications")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Notifications
        SectionHeader {
            first: true
            text: Tr.tr("Notifications")
        }

        SelectRow {
            first: true
            label: Tr.tr("Show in fullscreen")
            subtext: Tr.tr("Whether notifications appear over fullscreen apps")
            menuItems: root.notifFullscreenItems
            active: root.notifFullscreenItems[GlobalConfig.notifs.fullscreen]
            onSelected: item => GlobalConfig.notifs.fullscreen = root.notifFullscreenItems.indexOf(item)
        }

        ToggleRow {
            text: Tr.tr("Expire automatically")
            subtext: Tr.tr("Dismiss notifications after their timeout")
            checked: GlobalConfig.notifs.expire
            onToggled: GlobalConfig.notifs.expire = checked
        }

        ToggleRow {
            text: Tr.tr("Open expanded")
            subtext: Tr.tr("Show notifications expanded by default")
            checked: GlobalConfig.notifs.openExpanded
            onToggled: GlobalConfig.notifs.openExpanded = checked
        }

        StepperRow {
            label: Tr.tr("Default timeout")
            // TRANSLATORS: ms is the millisecond unit, leave it untranslated
            subtext: Tr.tr("Time before a notification dismisses (ms)")
            value: GlobalConfig.notifs.defaultExpireTimeout
            from: 1000
            to: 60000
            stepSize: 500
            onMoved: v => GlobalConfig.notifs.defaultExpireTimeout = Math.round(v)
        }

        StepperRow {
            last: true
            label: Tr.tr("Group preview count")
            subtext: Tr.tr("Notifications shown per group before collapsing")
            value: GlobalConfig.notifs.groupPreviewNum
            from: 1
            to: 10
            stepSize: 1
            onMoved: v => GlobalConfig.notifs.groupPreviewNum = Math.round(v)
        }

        // Toasts
        SectionHeader {
            text: Tr.tr("Toasts")
        }

        SelectRow {
            first: true
            label: Tr.tr("Show in fullscreen")
            subtext: Tr.tr("Whether toasts appear over fullscreen apps")
            menuItems: root.toastFullscreenItems
            active: root.toastFullscreenItems[Math.max(0, root.toastFullscreenValues.indexOf(GlobalConfig.utilities.toasts.fullscreen))]
            onSelected: item => GlobalConfig.utilities.toasts.fullscreen = root.toastFullscreenValues[root.toastFullscreenItems.indexOf(item)]
        }

        StepperRow {
            last: true
            label: Tr.tr("Visible toasts")
            subtext: Tr.tr("Maximum number of toasts shown at once")
            value: GlobalConfig.utilities.maxToasts
            from: 1
            to: 10
            stepSize: 1
            onMoved: v => GlobalConfig.utilities.maxToasts = Math.round(v)
        }
    }
}
