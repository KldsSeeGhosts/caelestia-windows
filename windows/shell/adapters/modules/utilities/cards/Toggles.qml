pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import QtQuick.Layouts
import Caelestia.Components
import Caelestia.Config
import Caelestia.I18n
import Caelestia.State
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus
import qs.modules.bar.popouts as BarPopouts

StyledRect {
    id: root

    required property ScreenState screenState
    required property BarPopouts.Wrapper popouts

    readonly property var quickToggles: {
        const seenIds = new Set();
        return Config.utilities.quickToggles.values.filter(item => {
            if (!item.enabled || seenIds.has(item.id))
                return false;
            seenIds.add(item.id);
            return true;
        });
    }
    readonly property int splitIndex: Math.ceil(quickToggles.length / 2)
    readonly property bool needExtraRow: quickToggles.length > 6

    implicitHeight: layout.implicitHeight + Tokens.padding.extraLargeIncreased

    radius: Tokens.rounding.large
    color: Colours.tPalette.m3surfaceContainer

    ColumnLayout {
        id: layout

        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        StyledText {
            text: Tr.tr("Quick toggles")
            font: Tokens.font.body.medium
        }

        QuickToggleRow {
            model: root.needExtraRow ? root.quickToggles.slice(0, root.splitIndex) : root.quickToggles
        }

        QuickToggleRow {
            visible: root.needExtraRow
            model: root.needExtraRow ? root.quickToggles.slice(root.splitIndex) : []
        }
    }

    component QuickToggleRow: ButtonRow {
        property alias model: repeater.model

        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        Repeater {
            id: repeater

            delegate: DelegateChooser {
                role: "id"

                DelegateChoice {
                    roleValue: "wifi"
                    delegate: Toggle {
                        icon: "wifi"
                        checked: Nmcli.wifiEnabled
                        enabled: Nmcli.controlsEnabled && Nmcli.adapterPresent
                        onClicked: Nmcli.enableWifi(!Nmcli.wifiEnabled)
                    }
                }
                DelegateChoice {
                    roleValue: "bluetooth"
                    delegate: Toggle {
                        icon: "bluetooth"
                        checked: WindowsBluetooth.radioEnabled
                        enabled: WindowsBluetooth.canToggleRadio
                        onClicked: WindowsBluetooth.setRadioEnabled(!WindowsBluetooth.radioEnabled)
                    }
                }
                DelegateChoice {
                    roleValue: "mic"
                    delegate: Toggle {
                        icon: "mic"
                        checked: !Audio.sourceMuted
                        enabled: Audio.inputControlsAvailable
                        onClicked: Audio.setSourceMuted(!Audio.sourceMuted)
                    }
                }
                DelegateChoice {
                    roleValue: "settings"
                    delegate: Toggle {
                        icon: "settings"
                        inactiveOnColour: Colours.palette.m3onSurfaceVariant
                        isToggle: false
                        onClicked: {
                            // Upstream opens the staged Nexus settings window.
                            // The combined Windows host stages modules/nexus and
                            // its WindowFactory, so this is the original path
                            // instead of the previous "open shell.json in an
                            // editor" stand-in.
                            WindowFactory.create();
                            root.screenState.utilities = false;
                        }
                    }
                }
                DelegateChoice {
                    roleValue: "dnd"
                    delegate: Toggle {
                        icon: "notifications_off"
                        enabled: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1" && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
                        checked: Notifs.doNotDisturb
                        onClicked: Notifs.doNotDisturb = !Notifs.doNotDisturb
                    }
                }
                DelegateChoice {
                    delegate: Toggle {
                        // Preserve configured positions without pretending an
                        // unsupported Windows service can be activated.
                        required property var modelData
                        icon: ({
                            gameMode: "gamepad", wallpaperPlaying: "smart_display", vpn: "vpn_key"
                        })[modelData.id] ?? "block"
                        enabled: false
                    }
                }
            }
        }
    }

    component Toggle: IconButton {
        inactiveColour: Colours.layer(Colours.palette.m3surfaceContainerHighest, 2)
        fillWidth: true
        isToggle: true
        isRound: true
        shapeMorph: true
    }
}
