pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.utils

Item {
    id: root

    required property Brightness.Monitor monitor
    required property ScreenState screenState

    required property real volume
    required property bool muted
    required property real sourceVolume
    required property bool sourceMuted
    required property real brightness

    // Windows-localized hooks. Both default to the upstream Linux behavior; the
    // bounded Windows brightness host stages this content for the brightness
    // row only and disables the audio rows. With brightness read-only or a
    // monitor whose route is unsupported, the original slider is disabled and
    // dimmed instead of issuing a write.
    property bool audioControlsEnabled: true
    property bool brightnessControlsEnabled: true
    // Windows hook: monotonic serial bumped by the bounded brightness host
    // after a denied or failed write. A drag removed the slider's value
    // binding, so reassigning the unchanged confirmed value alone never moves
    // the handle; this serial is what restores the displayed value. It stays 0
    // and inert on Linux, keeping the upstream behavior unchanged.
    property int brightnessResyncSerial: 0

    implicitWidth: layout.implicitWidth + Tokens.padding.large + layout.anchors.horizontalCenterOffset * 2
    implicitHeight: layout.implicitHeight + Tokens.padding.large * 2

    ColumnLayout {
        id: layout

        anchors.centerIn: parent
        anchors.horizontalCenterOffset: CUtils.clamp(Tokens.padding.large - Config.border.thickness, 0, Tokens.padding.large) / 2
        spacing: Tokens.spacing.medium

        // Speaker volume
        CustomMouseArea {
            function onWheel(event: WheelEvent) {
                if (event.angleDelta.y > 0)
                    Audio.incrementVolume();
                else if (event.angleDelta.y < 0)
                    Audio.decrementVolume();
            }

            implicitWidth: Tokens.sizes.osd.sliderWidth
            implicitHeight: Tokens.sizes.osd.sliderHeight

            // Windows hook: the brightness host hides audio rather than
            // exposing a second, unconfigured service.
            visible: root.audioControlsEnabled
            Layout.preferredHeight: root.audioControlsEnabled ? Tokens.sizes.osd.sliderHeight : 0

            FilledSlider {
                anchors.fill: parent

                icon: Icons.getVolumeIcon(value, root.muted)
                value: root.volume
                to: GlobalConfig.services.maxVolume
                onMoved: Audio.setVolume(value)
            }
        }

        // Microphone volume
        WrappedLoader {
            shouldBeActive: root.audioControlsEnabled && Config.osd.enableMicrophone && (!Config.osd.enableBrightness || !root.screenState.session)

            sourceComponent: CustomMouseArea {
                function onWheel(event: WheelEvent) {
                    if (event.angleDelta.y > 0)
                        Audio.incrementSourceVolume();
                    else if (event.angleDelta.y < 0)
                        Audio.decrementSourceVolume();
                }

                implicitWidth: Tokens.sizes.osd.sliderWidth
                implicitHeight: Tokens.sizes.osd.sliderHeight

                FilledSlider {
                    anchors.fill: parent

                    icon: Icons.getMicVolumeIcon(value, root.sourceMuted)
                    value: root.sourceVolume
                    to: GlobalConfig.services.maxVolume
                    onMoved: Audio.setSourceVolume(value)
                }
            }
        }

        // Brightness
        WrappedLoader {
            shouldBeActive: Config.osd.enableBrightness

            sourceComponent: CustomMouseArea {
                function onWheel(event: WheelEvent) {
                    const monitor = root.monitor;
                    if (!monitor)
                        return;
                    if (event.angleDelta.y > 0)
                        monitor.setBrightness(monitor.brightness + GlobalConfig.services.brightnessIncrement);
                    else if (event.angleDelta.y < 0)
                        monitor.setBrightness(monitor.brightness - GlobalConfig.services.brightnessIncrement);
                }

                implicitWidth: Tokens.sizes.osd.sliderWidth
                implicitHeight: Tokens.sizes.osd.sliderHeight

                // Windows hook: disabled styling for read-only, software-only
                // and unsupported monitor routes. The handle still shows the
                // last observed value.
                enabled: root.brightnessControlsEnabled
                opacity: root.brightnessControlsEnabled ? 1 : 0.38

                FilledSlider {
                    id: brightnessSlider

                    anchors.fill: parent

                    enabled: root.brightnessControlsEnabled
                    icon: `brightness_${(Math.round(value * 6) + 1)}`
                    value: root.brightness
                    onMoved: root.monitor?.setBrightness(value)

                    // Windows hook: the serial is 0 and never changes on
                    // Linux, so this never runs there. After a denied write the
                    // drag has already broken the value binding above; the
                    // serial bump restores it and snaps the handle to the
                    // confirmed level.
                    Connections {
                        target: root
                        function onBrightnessResyncSerialChanged(): void {
                            brightnessSlider.value = Qt.binding(() => root.brightness);
                        }
                    }
                }
            }
        }
    }

    component WrappedLoader: Loader {
        required property bool shouldBeActive

        asynchronous: true
        Layout.preferredHeight: shouldBeActive ? Tokens.sizes.osd.sliderHeight : 0
        opacity: shouldBeActive ? 1 : 0
        active: opacity > 0
        visible: active

        Behavior on Layout.preferredHeight {
            Anim {
                type: Anim.Emphasized
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }
}
