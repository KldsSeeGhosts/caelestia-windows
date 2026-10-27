pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/AudioPage.qml.
//
// Upstream enables the volume slider whenever the stream is not muted, and both
// device lists are always interactive. The Windows facade separates observation
// from control: a device can be listed while its WASAPI volume interface is
// unavailable, controls can be off for the whole run, or the default output can
// be missing. The layout, icons and values stay upstream; every control is now
// gated on the facade's per-direction capability, and its reason is shown
// instead of leaving a dead slider or list row clickable.
PageBase {
    id: root

    title: Tr.tr("Audio")

    readonly property string controlsReason: {
        if (Audio.outputControlsAvailable && Audio.inputControlsAvailable)
            return "";
        if (!Audio.enabled || Audio.status !== "ready" || !Audio.controlsEnabled)
            return Audio.reason;
        const reasons = [];
        if (!Audio.outputControlsAvailable)
            reasons.push(Audio.outputReason || Audio.reason);
        if (!Audio.inputControlsAvailable)
            reasons.push(Audio.inputReason || Audio.reason);
        return reasons.join("\n");
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        ConnectedRect {
            readonly property bool shown: root.controlsReason.length > 0

            Layout.fillWidth: true
            visible: shown
            implicitHeight: shown ? controlsNote.implicitHeight + Tokens.padding.large * 2 : 0
            first: true
            last: true

            StyledText {
                id: controlsNote

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                visible: parent.shown

                text: root.controlsReason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        // Output
        SliderRow {
            first: true
            icon: Icons.getVolumeIcon(Audio.volume, Audio.muted)
            label: Tr.trCtx("Output", "audio output")
            valueLabel: Strings.percentOne(value)
            value: Audio.volume
            enabled: Audio.outputControlsAvailable && !Audio.muted
            onMoved: v => Audio.setVolume(v)
        }

        ToggleRow {
            text: Tr.trCtx("Muted", "audio output muted")
            checked: Audio.muted
            enabled: Audio.outputControlsAvailable
            onToggled: Audio.setStreamMuted(Audio.sink, checked)
        }

        AudioDeviceList {
            nodes: Audio.sinks
            currentId: Audio.sink?.id ?? -1
            iconName: "speaker"
            placeholderIcon: "speaker"
            placeholderText: Tr.trCtx("No output devices", "no audio outputs")
            controlsAvailable: Audio.outputControlsAvailable
            onSelected: node => Audio.setAudioSink(node)
        }

        // Input
        SliderRow {
            Layout.topMargin: Tokens.spacing.large - parent.spacing
            first: true
            icon: Icons.getMicVolumeIcon(Audio.sourceVolume, Audio.sourceMuted)
            label: Tr.trCtx("Input", "audio input")
            valueLabel: Strings.percentOne(value)
            value: Audio.sourceVolume
            enabled: Audio.inputControlsAvailable && !Audio.sourceMuted
            onMoved: v => Audio.setSourceVolume(v)
        }

        ToggleRow {
            text: Tr.trCtx("Muted", "audio input muted")
            checked: Audio.sourceMuted
            enabled: Audio.inputControlsAvailable
            onToggled: Audio.setStreamMuted(Audio.source, checked)
        }

        AudioDeviceList {
            nodes: Audio.sources
            currentId: Audio.source?.id ?? -1
            iconName: "mic"
            placeholderIcon: "mic_off"
            placeholderText: Tr.trCtx("No input devices", "no audio inputs")
            controlsAvailable: Audio.inputControlsAvailable
            onSelected: node => Audio.setAudioSource(node)
        }

        // Per-app volumes
        NavRow {
            Layout.topMargin: Tokens.spacing.large - parent.spacing
            first: true
            last: true

            icon: "tune"
            text: Tr.tr("App volumes")
            subtext: Audio.streams.length === 0 ? Tr.tr("No apps playing audio") : Tr.trN("%n app playing audio", "%n apps playing audio", Audio.streams.length)
            onClicked: root.nState.openSubPage(1)
        }
    }
}
