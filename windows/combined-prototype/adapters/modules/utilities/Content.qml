pragma ComponentBehavior: Bound

import "cards"
import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.modules.bar.popouts as BarPopouts

// Original upstream utilities layout. The Windows host keeps the keep-awake and
// recorder cards enabled in the combined profile; each card owns its Live gate,
// so the read-only profile shows the same cards with inert controls.
//
// The upstream RecordingDeleteModal is omitted with the recordings list: the
// Windows recorder writes its own folder and the original list/deletion flow
// depends on the Linux `caelestia record` directory layout.
Item {
    id: root

    required property var props
    required property ScreenState screenState
    required property BarPopouts.Wrapper popouts
    required property matrix4x4 deformMatrix

    readonly property int enabledCards: (idleInhibit.active ? 1 : 0) + (record.active ? 1 : 0) + (toggles.active ? 1 : 0)
    readonly property real nonAnimHeight: ((idleInhibit.item as IdleInhibit)?.nonAnimHeight ?? 0) + ((record.item as Record)?.nonAnimHeight ?? 0) + ((toggles.item as Toggles)?.implicitHeight ?? 0) + layout.spacing * Math.max(0, enabledCards - 1)

    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    ColumnLayout {
        id: layout

        anchors.fill: parent
        spacing: Tokens.spacing.medium

        Loader {
            id: idleInhibit

            Layout.fillWidth: true
            active: Config.utilities.cards.keepAwake
            visible: active

            sourceComponent: IdleInhibit {
                objectName: "utilitiesKeepAwake"
            }
        }

        Loader {
            id: record

            Layout.fillWidth: true
            active: Config.utilities.cards.recorder
            visible: active
            z: 1

            sourceComponent: Record {
                objectName: "utilitiesScreenRecorder"

                props: root.props
                screenState: root.screenState
            }
        }

        Loader {
            id: toggles

            Layout.fillWidth: true
            active: Config.utilities.cards.quickToggles
            visible: active

            sourceComponent: Toggles {
                objectName: "utilitiesQuickToggles"

                screenState: root.screenState
                popouts: root.popouts
            }
        }
    }
}
