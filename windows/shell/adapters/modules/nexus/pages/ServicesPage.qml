import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Services
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/ServicesPage.qml.
//
// Every polling, unit and scheme control is upstream and writes the same
// GlobalConfig keys the installed shell reads. Two Linux-only pieces are
// replaced:
//   * `Lyrics.preferredBackend` comes from the upstream Caelestia.Services
//     module, which the portable Windows build excludes (windows/README.md), so
//     the lyrics-backend select becomes an honest "unavailable" row;
//   * the page keeps the default-player select, because the staged Players
//     facade is backed by GSMTC and reports real identities.
PageBase {
    id: root

    // GPU types, ordered to match config::GpuType (Auto, Nvidia, Generic, None)
    readonly property list<MenuItem> gpuItems: [
        MenuItem {
            text: Tr.trCtx("Auto", "gpu type")
        },
        MenuItem {
            text: "NVIDIA"
        },
        MenuItem {
            text: Tr.trCtx("Generic", "gpu type")
        },
        MenuItem {
            text: Tr.trCtx("None", "gpu type")
        }
    ]

    title: Tr.tr("Services")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Detected running players, used as default-player options
        Variants {
            id: playerVariants

            model: [...new Set(Players.list.map(p => Players.getIdentity(p)).filter(id => id))]

            MenuItem {
                required property string modelData

                text: modelData
                icon: modelData === GlobalConfig.services.defaultPlayer ? "check" : ""
                activeIcon: "music_note"
            }
        }

        // Notifications
        SectionHeader {
            first: true
            text: Tr.tr("Notifications")
        }

        NavRow {
            first: true
            last: true
            icon: "notifications"
            text: Tr.tr("Notifications")
            subtext: Tr.tr("Notifications, toasts, timeouts")
            onClicked: root.nState.openSubPage(1)
        }

        // Polling
        SectionHeader {
            text: Tr.tr("Polling")
        }

        StepperRow {
            first: true
            label: Tr.tr("Media refresh")
            // TRANSLATORS: ms is the millisecond unit, leave it untranslated
            subtext: Tr.tr("How often the media position updates (ms)")
            value: GlobalConfig.dashboard.mediaUpdateInterval
            from: 100
            to: 2000
            stepSize: 50
            onMoved: v => GlobalConfig.dashboard.mediaUpdateInterval = v
        }

        StepperRow {
            label: Tr.tr("System stats refresh")
            // TRANSLATORS: CPU and GPU are hardware abbreviations, leave them untranslated
            subtext: Tr.tr("CPU, memory and GPU update interval (seconds)")
            value: GlobalConfig.dashboard.resourceUpdateInterval / 1000
            from: 0.5
            to: 10
            stepSize: 0.5
            onMoved: v => GlobalConfig.dashboard.resourceUpdateInterval = Math.round(v * 1000)
        }

        StepperRow {
            last: true
            label: Tr.tr("Wi-Fi rescan")
            subtext: Tr.tr("How often available networks are rescanned (seconds)")
            value: GlobalConfig.nexus.networkRescanInterval / 1000
            from: 5
            to: 120
            stepSize: 5
            onMoved: v => GlobalConfig.nexus.networkRescanInterval = Math.round(v * 1000)
        }

        // Media & lyrics
        SectionHeader {
            text: Tr.tr("Media & lyrics")
        }

        // Upstream selects the synced-lyrics source here. The Windows build has
        // no lyrics service (no Local/LRCLIB/NetEase backend is compiled or
        // staged), so the row states that instead of offering a dead choice.
        InfoRow {
            first: true
            label: Tr.tr("Lyrics backend")
            subtext: Tr.trCtx("Unavailable", "lyrics service state")
            value: ""
        }

        SelectRow {
            last: true
            label: Tr.tr("Default player")
            subtext: Tr.tr("Preferred media player when several are open")
            menuItems: playerVariants.instances
            active: menuItems.find(i => i.text === GlobalConfig.services.defaultPlayer) ?? null
            fallbackIcon: "music_note"
            fallbackText: GlobalConfig.services.defaultPlayer || Tr.trCtx("Auto", "default media player")
            onSelected: item => GlobalConfig.services.defaultPlayer = item.text
        }

        // Input increments
        SectionHeader {
            text: Tr.tr("Input increments")
        }

        StepperRow {
            first: true
            label: Tr.tr("Volume step")
            subtext: Tr.tr("Amount the volume changes per scroll (%)")
            value: Math.round(GlobalConfig.services.audioIncrement * 100)
            from: 1
            to: 50
            stepSize: 1
            onMoved: v => GlobalConfig.services.audioIncrement = v / 100
        }

        StepperRow {
            label: Tr.tr("Brightness step")
            subtext: Tr.tr("Amount the brightness changes per scroll (%)")
            value: Math.round(GlobalConfig.services.brightnessIncrement * 100)
            from: 1
            to: 50
            stepSize: 1
            onMoved: v => GlobalConfig.services.brightnessIncrement = v / 100
        }

        StepperRow {
            last: true
            label: Tr.tr("Max volume")
            subtext: Tr.tr("Upper limit for output volume (%)")
            value: Math.round(GlobalConfig.services.maxVolume * 100)
            from: 50
            to: 200
            stepSize: 5
            onMoved: v => GlobalConfig.services.maxVolume = v / 100
        }

        // Service tuning
        SectionHeader {
            text: Tr.tr("Service tuning")
        }

        StepperRow {
            first: true
            // TRANSLATORS: bars of a spectrum analyser, not the taskbar
            label: Tr.tr("Visualiser bars")
            subtext: Tr.tr("Number of bars in the audio visualisers")
            value: GlobalConfig.services.visualiserBars
            from: 10
            to: 120
            stepSize: 2
            onMoved: v => GlobalConfig.services.visualiserBars = v
        }

        ToggleRow {
            text: Tr.tr("Smart colour scheme")
            subtext: Tr.tr("Derive theme mode and variant from the wallpaper")
            checked: GlobalConfig.services.smartScheme
            onToggled: GlobalConfig.services.smartScheme = checked
        }

        SelectRow {
            last: true
            label: Tr.tr("GPU")
            subtext: Gpu.name ? Tr.tr("Monitoring: %1").arg(Gpu.name) : Tr.tr("Override for GPU type")
            menuOnTop: true
            menuItems: root.gpuItems
            active: root.gpuItems[GlobalConfig.services.gpuType]
            onSelected: item => GlobalConfig.services.gpuType = root.gpuItems.indexOf(item)
        }
    }
}
