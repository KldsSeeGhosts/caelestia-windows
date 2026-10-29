import "performance"
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.UPower
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Services
import qs.components
import qs.services

Item {
    id: root

    implicitWidth: placeholder.active ? Tokens.sizes.dashboard.perfPlaceholderWidth : content.implicitWidth
    implicitHeight: placeholder.active ? placeholder.implicitHeight + Tokens.padding.extraLarge * 2 : content.implicitHeight

    Loader {
        id: placeholder

        anchors.centerIn: parent
        active: !Config.dashboard.performance.showCpu && !(Config.dashboard.performance.showGpu && Gpu.type !== GpuType.None) && !Config.dashboard.performance.showMemory && !Config.dashboard.performance.showStorage && !Config.dashboard.performance.showNetwork && !(UPower.displayDevice.isLaptopBattery && Config.dashboard.performance.showBattery)
        asynchronous: true

        sourceComponent: ColumnLayout {
            spacing: Tokens.spacing.medium

            MaterialIcon {
                Layout.alignment: Qt.AlignHCenter
                text: "tune"
                fontStyle: Tokens.font.icon.builders.extraLarge.scale(2).build()
                color: Colours.palette.m3onSurfaceVariant
            }

            StyledText {
                Layout.topMargin: -Tokens.spacing.small
                Layout.alignment: Qt.AlignHCenter
                text: Tr.tr("No widgets enabled")
                font: Tokens.font.title.large
                color: Colours.palette.m3onSurface
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: Tr.tr("Enable widgets in the dashboard settings")
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }
        }
    }

    RowLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Tokens.spacing.medium
        visible: !placeholder.active

        ColumnLayout {
            id: mainColumn

            Layout.fillWidth: true
            spacing: Tokens.spacing.medium

            RowLayout {
                spacing: Tokens.spacing.medium
                visible: cpuCard.active || gpuCard.active

                WrappedLoader {
                    id: cpuCard

                    active: Config.dashboard.performance.showCpu

                    sourceComponent: HeroCard {
                        icon: "memory"
                        label: Tr.tr("CPU")
                        subLabel: Cpu.name
                        usage: Cpu.percentage
                        temperature: Cpu.temperature
                        accent: Colours.palette.m3primary

                        ServiceRef {
                            service: Cpu
                        }
                    }
                }

                WrappedLoader {
                    id: gpuCard

                    active: Config.dashboard.performance.showGpu && Gpu.type !== GpuType.None

                    sourceComponent: HeroCard {
                        icon: "desktop_windows"
                        label: Tr.tr("GPU")
                        subLabel: Gpu.name || (Gpu.detecting ? Tr.tr("Detecting GPU...") : Tr.trCtx("None", "GPU name"))
                        usage: Gpu.percentage
                        temperature: Gpu.temperature
                        // Windows: the card adds a dedicated VRAM meter from the service.
                        memorySource: Gpu
                        accent: Colours.palette.m3secondary

                        ServiceRef {
                            service: Gpu
                        }
                    }
                }
            }

            RowLayout {
                spacing: Tokens.spacing.medium
                visible: storageCard.active || networkCard.active || memoryCard.active

                WrappedLoader {
                    id: storageCard

                    active: Config.dashboard.performance.showStorage
                    sourceComponent: StorageCard {}
                }

                WrappedLoader {
                    id: networkCard

                    active: Config.dashboard.performance.showNetwork
                    sourceComponent: NetworkCard {}
                }

                WrappedLoader {
                    id: memoryCard

                    active: Config.dashboard.performance.showMemory
                    sourceComponent: MemoryCard {}
                }
            }
        }

        WrappedLoader {
            Layout.fillWidth: false
            active: UPower.displayDevice.isLaptopBattery && Config.dashboard.performance.showBattery
            sourceComponent: BatteryTank {}
        }
    }

    component WrappedLoader: Loader {
        id: wrapped

        // Windows: cards size to their text ("9.9 / 63.6 GiB" becomes
        // "10.0 / 63.6 GiB"). Every implicit size change animates the whole
        // dashboard and re-runs the pane loading in Content.qml, so the
        // dropdown shifted and stalled while values changed. Cards only grow.
        property real widest: 0
        property real tallest: 0
        readonly property real itemWidth: item?.implicitWidth ?? 0
        readonly property real itemHeight: item?.implicitHeight ?? 0

        onItemWidthChanged: widest = Math.max(widest, itemWidth)
        onItemHeightChanged: tallest = Math.max(tallest, itemHeight)

        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredWidth: widest > 0 ? widest : -1
        Layout.preferredHeight: tallest > 0 ? tallest : -1
        visible: active
    }
}
