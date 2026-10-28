pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.components
import qs.services
import "../../services/DictationLogic.js" as Logic

// Original custom overlay indicator at 621dccaf. Windows changes are the
// status adapter and window boundary. The original pill lives in DictationPill.
Scope {
    id: root

    readonly property ShellScreen targetScreen: Logic.targetScreen(Quickshell.screens, Dictation.screenName)
    readonly property var window: windowLoader.item
    // A URL boundary keeps the native-only PanelWindow out of offscreen tests.
    property url windowSource: Qt.resolvedUrl("DictationWindow.qml")

    Loader {
        id: windowLoader

        active: false
        opacity: 0

        states: State {
            name: "active"
            when: (Dictation.state === Dictation.listeningState || Dictation.state === Dictation.processingState)
                && root.targetScreen !== null

            PropertyChanges {
                windowLoader.opacity: 1
                windowLoader.active: true
            }
        }

        transitions: [
            Transition {
                from: ""
                to: "active"
                SequentialAnimation {
                    PropertyAction { property: "active" }
                    Anim { property: "opacity"; type: Anim.DefaultEffects }
                }
            },
            Transition {
                from: "active"
                to: ""
                SequentialAnimation {
                    Anim { property: "opacity"; type: Anim.DefaultEffects }
                    PropertyAction { property: "active" }
                }
            }
        ]

        source: root.windowSource
        onLoaded: {
            item.screen = Qt.binding(() => root.targetScreen);
            item.indicatorOpacity = Qt.binding(() => windowLoader.opacity);
        }
    }
}
