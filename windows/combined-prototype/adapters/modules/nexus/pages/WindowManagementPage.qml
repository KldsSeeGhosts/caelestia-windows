import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components.controls
import qs.modules.nexus.common

// Windows-only page; no upstream counterpart.
PageBase {
    id: root

    readonly property list<MenuItem> modeItems: [
        MenuItem {
            text: Tr.tr("Observe")
        },
        MenuItem {
            text: Tr.tr("Interactive")
        }
    ]

    readonly property bool tilingEnabled: GlobalConfig.windows?.tiling?.enabled ?? false
    readonly property bool tilingInteractive: (GlobalConfig.windows?.tiling?.mode ?? "observe") === "interactive"
    readonly property bool borderColours: GlobalConfig.windows?.tiling?.borderColours ?? true
    readonly property bool focusEnabled: GlobalConfig.windows?.focusFollowsMouse?.enabled ?? false
    readonly property int focusDelay: GlobalConfig.windows?.focusFollowsMouse?.delay ?? 100

    title: Tr.tr("Window management")

    // GlobalConfig.windows is one QVariantMap, not a sub-object: assigning a
    // nested member does not persist, so copy the map and write it back whole.
    function setWindowsOption(group: string, key: string, value: var): void {
        const windows = JSON.parse(JSON.stringify(GlobalConfig.windows ?? {}));
        windows[group] = Object.assign(windows[group] ?? {}, { [key]: value });
        GlobalConfig.windows = windows;
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Tiling
        SectionHeader {
            first: true
            text: Tr.tr("Tiling")
        }

        ToggleRow {
            first: true
            text: Tr.tr("Tiling")
            subtext: Tr.tr("Turn the window tiler on")
            checked: root.tilingEnabled
            onToggled: root.setWindowsOption("tiling", "enabled", checked)
        }

        SelectRow {
            enabled: root.tilingEnabled
            opacity: enabled ? 1 : 0.38
            label: Tr.tr("Mode")
            subtext: Tr.tr("Interactive tiles only apps in the tiling list")
            menuItems: root.modeItems
            active: root.tilingInteractive ? root.modeItems[1] : root.modeItems[0]
            onSelected: item => root.setWindowsOption("tiling", "mode", item === root.modeItems[1] ? "interactive" : "observe")
        }

        InfoRow {
            label: Tr.tr("Tiling list")
            subtext: Tr.tr("Apps matched by include rules. Edit in shell.json")
            value: {
                const include = GlobalConfig.windows?.tiling?.include;
                return Array.isArray(include) ? include.length : String(include ?? "").split(";").filter(s => s.trim()).length;
            }
        }

        ToggleRow {
            last: true
            disabled: !root.tilingEnabled
            text: Tr.tr("Border colours")
            subtext: Tr.tr("Colour window borders by focus")
            checked: root.borderColours
            onToggled: root.setWindowsOption("tiling", "borderColours", checked)
        }

        // Gaps
        SectionHeader {
            text: Tr.tr("Gaps")
        }

        StepperRow {
            first: true
            enabled: root.tilingEnabled
            label: Tr.tr("Inner gap")
            subtext: Tr.tr("Space around each window; two windows get double (px)")
            value: GlobalConfig.windows?.tiling?.gapsIn ?? 5
            from: 0
            to: 100
            stepSize: 1
            onMoved: v => root.setWindowsOption("tiling", "gapsIn", v)
        }

        StepperRow {
            enabled: root.tilingEnabled
            label: Tr.tr("Outer gap")
            subtext: Tr.tr("Space between windows and the screen edge (px)")
            value: GlobalConfig.windows?.tiling?.gapsOut ?? 10
            from: 0
            to: 100
            stepSize: 1
            onMoved: v => root.setWindowsOption("tiling", "gapsOut", v)
        }

        StepperRow {
            last: true
            enabled: root.tilingEnabled
            label: Tr.tr("Single window gap")
            subtext: Tr.tr("Edge space when only one window is tiled (px)")
            value: GlobalConfig.windows?.tiling?.singleWindowGapsOut ?? 20
            from: 0
            to: 100
            stepSize: 1
            onMoved: v => root.setWindowsOption("tiling", "singleWindowGapsOut", v)
        }

        // Focus
        SectionHeader {
            text: Tr.tr("Focus")
        }

        ToggleRow {
            first: true
            text: Tr.tr("Focus follows mouse")
            subtext: Tr.tr("Focus the window under the pointer")
            checked: root.focusEnabled
            onToggled: root.setWindowsOption("focusFollowsMouse", "enabled", checked)
        }

        StepperRow {
            enabled: root.focusEnabled
            label: Tr.tr("Focus delay")
            subtext: Tr.tr("Wait before focus changes (ms)")
            value: root.focusDelay
            from: 0
            to: 1000
            stepSize: 50
            onMoved: v => root.setWindowsOption("focusFollowsMouse", "delay", v)
        }

        ToggleRow {
            last: true
            disabled: !root.focusEnabled
            text: Tr.tr("Raise on focus")
            subtext: Tr.tr("Bring the focused window to the front")
            checked: GlobalConfig.windows?.focusFollowsMouse?.raise ?? false
            onToggled: root.setWindowsOption("focusFollowsMouse", "raise", checked)
        }
    }
}
