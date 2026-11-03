pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import qs.modules.nexus

ColumnLayout {
    id: root

    required property string title
    required property NexusState nState
    property bool isSubPage
    readonly property int cappedWidth: Math.min(Tokens.sizes.nexus.maxContentWidth, width)
    readonly property alias flickable: flickable

    default property Item contentChild

    spacing: Tokens.spacing.extraLargeIncreased

    MouseArea { // Prevent clicks from reaching flickable
        z: 1
        implicitWidth: header.implicitWidth
        implicitHeight: header.implicitHeight - Layout.bottomMargin
        Layout.bottomMargin: -flickable.topMargin // Extra height to block clicks on flickable top margin
        onClicked: focus = true

        RowLayout {
            id: header

            spacing: Tokens.spacing.largeIncreased

            Loader {
                visible: active
                active: root.isSubPage
                asynchronous: true
                sourceComponent: IconButton {
                    icon: "arrow_back"
                    font: Tokens.font.icon.medium
                    type: IconButton.Tonal
                    isRound: true
                    inactiveColour: Colours.tPalette.m3surfaceContainerHigh
                    inactiveOnColour: Colours.palette.m3onSurfaceVariant
                    onClicked: root.nState.closeSubPage()
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: root.title
                font: Tokens.font.title.large
                elide: Text.ElideRight
            }
        }
    }

    VerticalFadeFlickable {
        id: flickable

        Layout.fillWidth: true
        Layout.fillHeight: true

        Layout.topMargin: -topMargin
        topMargin: Tokens.padding.large
        bottomMargin: Tokens.padding.extraLarge

        contentHeight: root.contentChild?.implicitHeight ?? 0
        contentItem.children: [root.contentChild]

        TapHandler {
            onTapped: flickable.focus = true
        }

        // Windows port (#210): Tab moves focus but the flickable does not
        // follow it. Scroll a keyboard-focused control in this page into view.
        // The animation writes revealTo, and only that write may set contentY.
        // A pointer scroll or any other contentY change cancels it. Focus that
        // leaves this page, including the flickable's own tap focus, cancels
        // it too and does not start another.
        property bool revealWrite: false
        property real revealTo: 0

        onRevealToChanged: {
            revealWrite = true;
            contentY = revealTo;
            revealWrite = false;
        }
        onContentYChanged: {
            if (!revealWrite && revealAnim.running)
                revealAnim.stop();
        }
        onDraggingChanged: if (dragging) revealAnim.stop()
        onMovingChanged: if (moving) revealAnim.stop()

        Anim {
            id: revealAnim

            target: flickable
            property: "revealTo"
        }

        Connections {
            function onActiveFocusItemChanged(): void {
                if (!root) // the window can move focus while this page tears down
                    return;
                revealAnim.stop();
                const item = root.Window.activeFocusItem;
                if (!item)
                    return;
                let p = item;
                while (p && p !== flickable.contentItem)
                    p = p.parent;
                if (!p)
                    return;
                const y = item.mapToItem(flickable.contentItem, 0, 0).y;
                const pad = root.Tokens.padding.large;
                const min = -flickable.topMargin;
                const max = Math.max(min, flickable.contentHeight + flickable.bottomMargin - flickable.height);
                let to = flickable.contentY;
                if (y - pad < to)
                    to = y - pad;
                else if (y + item.height + pad > to + flickable.height)
                    to = y + item.height + pad - flickable.height;
                to = Math.max(min, Math.min(max, to));
                if (to !== flickable.contentY) {
                    revealTo = flickable.contentY;
                    revealAnim.from = flickable.contentY;
                    revealAnim.to = to;
                    revealAnim.restart();
                }
            }

            target: root.Window.window
        }
    }
}
