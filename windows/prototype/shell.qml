//@ pragma AppId org.caelestia.windows-probe
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia
import Caelestia.Blobs
import Caelestia.Config
import Caelestia.State
import Caelestia.Shaders
import qs.components
import qs.services
import qs.modules.bar.components as Bar
import qs.modules.dashboard.dash as Dashboard

// A component compatibility probe in a normal application window.
// The real bar/drawer service graph is deliberately outside this first gate.
ShellRoot {
    id: root

    property bool drawerOpen
    readonly property bool smoke: Quickshell.env("CAELESTIA_PROBE_SMOKE") === "1"

    settings.watchFiles: false

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }

    FloatingWindow {
        id: win

        title: "Caelestia Windows component probe"
        implicitWidth: 740
        implicitHeight: 460
        color: Colours.palette.m3background
        onClosed: Qt.quit()

        Rectangle {
            id: scene

            // Keep the specimen stable if the user's existing tiler resizes
            // this ordinary window. Do not change the tiler's configuration.
            anchors.centerIn: parent
            width: 740
            height: 460
            color: Colours.palette.m3background
            focus: true
            Keys.onEscapePressed: root.drawerOpen = false

            BlobGroup {
                id: surface

                color: Colours.palette.m3surfaceContainer
                smoothing: 24
            }

            BlobRect {
                x: 16
                y: 16
                width: 92
                height: scene.height - 32
                radius: Tokens.rounding.extraLarge
                group: surface
            }

            BlobRect {
                x: 108
                y: 96
                width: drawer.width
                height: drawer.height
                radius: Tokens.rounding.extraLarge
                group: surface
                visible: width > 0
            }

            Bar.Clock {
                id: clock

                x: 16 + (92 - width) / 2
                y: (scene.height - height) / 2

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.drawerOpen = !root.drawerOpen
                }
            }

            StyledText {
                x: 136
                y: 26
                text: "Caelestia on Windows"
                font: Tokens.font.title.large
            }

            StyledText {
                x: 136
                y: 60
                text: "Original clock, blob surfaces, rounded mask, and motion"
                color: Colours.palette.m3onSurfaceVariant
            }

            Item {
                id: drawer

                x: 108
                y: 96
                width: root.drawerOpen ? 220 : 0
                height: 290
                clip: true

                Behavior on width {
                    Anim {}
                }

                Dashboard.DateTime {
                    x: 24
                    width: 172
                }
            }

            ClipRect {
                x: 370
                y: 120
                width: 330
                height: 160
                radius: Tokens.rounding.extraLarge
                color: Colours.palette.m3surfaceContainer

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24

                    StyledText {
                        text: "Component compatibility"
                        font: Tokens.font.title.small
                    }
                    StyledText {
                        text: "Qt " + CUtils.qtVersion + " / API " + GraphicsInfo.api
                    }
                    StyledText {
                        text: "Click the clock to test motion.\nEscape closes the test drawer."
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                    }
                }
            }

            StyledText {
                x: 370
                y: 306
                width: 330
                wrapMode: Text.WordWrap
                text: "This is a component probe. The full bar,\nWindows services, and panel focus are next."
                color: Colours.palette.m3onSurfaceVariant
            }

            Component.onCompleted: {
                // Exercise the state module with only the isolated paths.
                console.log("CAELESTIA_PROBE_READY", CUtils.version,
                    PersistentState.doNotDisturb, Shaders.crossfade.url);
            }
        }
    }

    Timer {
        property int step

        running: root.smoke
        repeat: true
        interval: 1200
        onTriggered: {
            if (step === 0) {
                console.log("CAELESTIA_PROBE_GEOMETRY", scene.width, scene.height,
                    win.devicePixelRatio, scene.GraphicsInfo.api);
                const requestedScale = Quickshell.env("CAELESTIA_PROBE_SCALE");
                if (requestedScale !== "native" && Math.abs(win.devicePixelRatio - Number(requestedScale)) > 0.01) {
                    console.error("CAELESTIA_PROBE_FAIL: requested DPI was not applied");
                    Qt.exit(1);
                    return;
                }
                root.drawerOpen = true;
            } else if (step === 1) {
                if (clock.width <= 0 || drawer.width < 219) {
                    console.error("CAELESTIA_PROBE_FAIL: component dimensions");
                    Qt.exit(1);
                    return;
                }
                CUtils.saveItem(scene, Qt.resolvedUrl(Quickshell.env("CAELESTIA_PROBE_SCREENSHOT")), () => {
                    root.drawerOpen = false;
                }, () => {
                    console.error("CAELESTIA_PROBE_FAIL: screenshot");
                    Qt.exit(1);
                });
            } else if (step === 2) {
                if (root.drawerOpen || drawer.width > 1) {
                    console.error("CAELESTIA_PROBE_FAIL: close animation");
                    Qt.exit(1);
                    return;
                }
                console.log("CAELESTIA_PROBE_PASS");
                Qt.quit();
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 10000
        onTriggered: {
            console.error("CAELESTIA_PROBE_FAIL: timeout");
            Qt.exit(1);
        }
    }
}
