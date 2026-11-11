pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Components
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.components.widgets
import qs.components.wallpaper
import qs.services
import qs.modules.nexus.common

// Windows keeps the Nexus preview and appearance controls, with display
// targeting and the existing Wallpaper Engine group below the picker buttons.
PageBase {
    id: root

    title: Tr.tr("Wallpaper & style")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.large

        ClipRect {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: {
                const screen = root.nState?.screen;
                return screen ? implicitHeight / screen.height * screen.width : 0;
            }
            implicitHeight: {
                const screen = root.nState?.screen;
                return screen ? Math.min(Math.round(root.cappedWidth * 0.4),
                    root.cappedWidth / screen.width * screen.height) : 0;
            }
            color: Colours.tPalette.m3surfaceContainer
            radius: Tokens.rounding.large

            Loader {
                anchors.centerIn: parent
                opacity: Config.background.wallpaperEnabled ? 0 : 1
                active: opacity > 0
                sourceComponent: ColumnLayout {
                    spacing: Tokens.spacing.extraSmall
                    MaterialIcon {
                        Layout.alignment: Qt.AlignHCenter
                        text: "hide_image"
                        color: Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.extraLarge
                    }
                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: Tr.tr("Wallpaper disabled")
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.large
                    }
                }
                Behavior on opacity { Anim { type: Anim.SlowEffects } }
            }

            WallpaperImpl {
                anchors.fill: parent
                opacity: Config.background.wallpaperEnabled ? 1 : 0
                source: Wallpapers.currentForScreen(root.nState?.wallpaperTarget)
                Behavior on opacity { Anim { type: Anim.SlowEffects } }
            }
        }

        ButtonRow {
            Layout.alignment: Qt.AlignHCenter
            spacing: Tokens.spacing.small
            IconTextButton {
                icon: "wallpaper"
                text: Tr.tr("Wallpapers")
                font: Tokens.font.body.large
                isRound: true
                shapeMorph: true
                type: IconTextButton.Tonal
                horizontalPadding: Tokens.padding.extraLarge
                verticalPadding: Tokens.padding.medium
                disabled: !Config.background.wallpaperEnabled
                onClicked: root.nState.openSubPage(1)
            }
            IconTextButton {
                icon: "palette"
                text: Tr.tr("Colours")
                font: Tokens.font.body.large
                isRound: true
                shapeMorph: true
                type: IconTextButton.Tonal
                horizontalPadding: Tokens.padding.extraLarge
                verticalPadding: Tokens.padding.medium
                onClicked: root.nState.openSubPage(3)
            }
        }

        WallpaperDisplays {
            Layout.fillWidth: true
            targetScreen: root.nState?.wallpaperTarget
            onTargetSelected: screen => root.nState.wallpaperTarget = screen
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.extraSmall / 2
            ToggleRow {
                first: true
                text: Tr.tr("Display wallpaper")
                checked: Config.background.wallpaperEnabled
                onToggled: GlobalConfig.background.wallpaperEnabled = checked
            }
            ToggleRow {
                text: Tr.tr("Transparency")
                subtext: Tr.tr("Base %1, layers %2").arg(Colours.transparency.base).arg(Colours.transparency.layers)
                checked: Colours.transparency.enabled
                onToggled: GlobalConfig.appearance.transparency.enabled = checked
            }
            ToggleRow {
                last: true
                text: Tr.tr("Dark theme")
                checked: !Colours.light
                onToggled: Colours.setMode(checked ? "dark" : "light")
            }
        }

        WallpaperEngineSettings {
            Layout.fillWidth: true
        }
    }
}
