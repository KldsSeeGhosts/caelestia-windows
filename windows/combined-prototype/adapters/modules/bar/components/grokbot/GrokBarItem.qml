pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services
import ".."

Item {
    id: root

    required property var bar

    readonly property var attentionBot: GrokBot.attentionBot
    readonly property bool hasAttention: attentionBot !== null
    readonly property bool isWaiting: GrokBot.counts.awaiting > 0
    readonly property bool isWorking: GrokBot.counts.working > 0
    readonly property bool hasUnread: GrokBot.counts.unread > 0

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: Tokens.sizes.bar.innerWidth

    StateLayer {
        anchors.fill: parent
        radius: Tokens.rounding.full
        onClicked: {
            const center = root.mapToItem(root.bar, 0, root.height / 2).y;
            root.bar.popouts.currentName = (root.bar.popouts.currentName === "grokbot" && root.bar.popouts.hasCurrent) ? "" : "grokbot";
            root.bar.popouts.currentCenter = center;
            root.bar.popouts.hasCurrent = (root.bar.popouts.currentName === "grokbot");
        }
    }

    // When there is an attention bot (awaiting answer, working, or unread)
    Loader {
        anchors.centerIn: parent
        width: Math.round(root.width * 0.76)
        height: Math.round(root.height * 0.76)
        active: root.hasAttention
        visible: active

        sourceComponent: Avatar {
            anchors.fill: parent
            shape: root.attentionBot?.shape ?? "squircle"
            fill: GrokBot.colorFor(root.attentionBot, Colours.palette.m3primary)
            face: GrokBot.faceFor(root.attentionBot)
            animate: true
        }
    }

    // Default icon when idle (styled Grok Bot mark)
    Loader {
        anchors.centerIn: parent
        width: Math.round(root.width * 0.68)
        height: Math.round(root.height * 0.68)
        active: !root.hasAttention
        visible: active

        sourceComponent: Item {
            anchors.fill: parent

            Avatar {
                anchors.fill: parent
                shape: "squircle"
                fill: Colours.palette.m3surfaceVariant
                cutoutEyes: true
                face: "neutral"
                animate: false
                opacity: GrokBot.appRunning ? 0.9 : 0.45
            }
        }
    }

    // Small indicator badge for waiting or unread counts
    StyledRect {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 2
        anchors.rightMargin: 2
        implicitWidth: 8
        implicitHeight: 8
        radius: 4
        visible: root.isWaiting || root.hasUnread
        color: root.isWaiting ? Colours.palette.m3error : Colours.palette.m3tertiary
    }
}
