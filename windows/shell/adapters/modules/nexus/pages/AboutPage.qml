import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Windows
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/AboutPage.qml.
//
// Upstream spawns `quickshell --version` and `sh -c "caelestia --version"`.
// Neither exists on Windows: the backend executable is qs.exe and there is no
// POSIX shell, so both rows would stay on "…" forever and each Process would
// log a spawn failure. The hero, section layout and order are upstream.
// Replaced rows:
//   * hostname comes from COMPUTERNAME instead of /etc/hostname;
//   * the Linux distro/kernel/firmware rows are dropped, because the staged
//     SysInfo facade reports them empty (windows/docs/USER-GUIDE.md);
//   * the CLI row is dropped (the Linux caelestia CLI is not installed here)
//     and the Quickshell row reads the native SystemMonitor platform data.
PageBase {
    id: root

    // Plugin support is not wired up yet; always 0 for now
    readonly property int pluginCount: 0

    readonly property string hostName: Quickshell.env("COMPUTERNAME") ?? ""
    readonly property string platform: {
        const name = SystemMonitor.osName;
        if (!name)
            return "";
        const version = SystemMonitor.osVersion;
        return version ? `${name} ${version}` : name;
    }
    readonly property string board: {
        const vendor = SystemMonitor.boardVendor;
        const model = SystemMonitor.boardModel;
        return [vendor, model].filter(part => part).join(" ");
    }

    title: Tr.tr("About")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Hero
        ConnectedRect {
            Layout.fillWidth: true
            first: true
            last: true
            implicitHeight: hero.implicitHeight + Tokens.padding.extraLarge * 2

            ColumnLayout {
                id: hero

                anchors.centerIn: parent
                width: parent.width - Tokens.padding.largeIncreased * 2
                spacing: Tokens.spacing.small

                AnimatedLogo {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: implicitWidth
                    Layout.preferredHeight: implicitHeight
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Tokens.spacing.small
                    text: "Caelestia"
                    font: Tokens.font.headline.builders.large.width(110).build()
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: CUtils.version ? `v${CUtils.version}` : "…"
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.medium
                }
            }
        }

        // System
        SectionHeader {
            text: Tr.tr("System")
        }

        InfoRow {
            first: true
            label: Tr.tr("Hostname")
            value: root.hostName
        }

        InfoRow {
            label: Tr.tr("Platform")
            value: root.platform
        }

        InfoRow {
            label: Tr.trCtx("Device", "system model name")
            value: root.board
        }

        InfoRow {
            label: Tr.trCtx("Window manager", "the Windows compositor")
            value: SysInfo.wm
        }

        InfoRow {
            last: true
            label: Tr.tr("Uptime")
            value: SysInfo.uptimeShort
        }

        // Software
        SectionHeader {
            text: Tr.tr("Software")
        }

        InfoRow {
            first: true
            label: Tr.trCtx("Shell", "the caelestia shell itself, not a unix shell")
            value: CUtils.version || "…"
        }

        InfoRow {
            last: true
            label: "Qt"
            value: CUtils.qtVersion || "…"
        }

        // Plugins
        SectionHeader {
            text: Tr.tr("Plugins")
        }

        InfoRow {
            first: true
            last: true
            label: Tr.tr("Loaded plugins")
            value: root.pluginCount.toString()
        }
    }
}
