pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.containers
import qs.services
import qs.modules.nexus

VerticalFadeFlickable {
    id: root

    required property NexusState nState
    property string query
    objectName: "nexusSearchResults"

    // Windows: upstream's search field only sets searchOpen. Build results from
    // the same page registry, retaining the original page indices and paths.
    readonly property var results: {
        const term = root.query.trim().toLocaleLowerCase();
        const matches = [];
        for (let i = 0; i < PageRegistry.pages.length; ++i) {
            const page = PageRegistry.pages[i];
            if (!term || (page.label + " " + page.description).toLocaleLowerCase().includes(term))
                matches.push({ pageIndex: i, path: [], label: page.label, description: page.description, icon: page.icon, category: page.category, noFill: page.noFill });
            if (term) {
                for (const sub of (page.searchSubPages ?? [])) {
                    if ((sub.label + " " + (sub.keywords ?? "")).toLocaleLowerCase().includes(term))
                        matches.push({ pageIndex: i, path: sub.path, label: sub.label, description: page.label, icon: page.icon, category: page.category, noFill: page.noFill });
                }
            }
        }
        return matches;
    }

    function openResult(result): void {
        if (!result)
            return;
        root.nState.searchNavigate(result.pageIndex, result.path);
    }

    function openFirstMatch(): void {
        if (root.query.trim() && root.results.length)
            root.openResult(root.results[0]);
    }

    topMargin: Tokens.padding.large
    bottomMargin: Tokens.padding.large
    contentHeight: content.implicitHeight

    TapHandler {
        onTapped: root.focus = true
    }

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Tokens.spacing.extraSmall

        Repeater {
            id: list

            model: root.results

            StyledRect {
                id: item

                required property var modelData
                required property int index

                readonly property bool isCurrentPage: modelData.pageIndex === root.nState.currentPageIdx && modelData.path.length === 0
                readonly property bool isCategoryStart: index === 0 || list.model[index - 1]?.category !== modelData.category
                readonly property bool isCategoryEnd: index >= list.model.length - 1 || list.model[index + 1]?.category !== modelData.category

                Layout.fillWidth: true
                Layout.topMargin: index !== 0 && isCategoryStart ? Tokens.spacing.medium : 0
                implicitHeight: {
                    const h = layout.implicitHeight + layout.anchors.margins * 2;
                    return h % 2 === 0 ? h : h + 1;
                }

                color: isCurrentPage ? Colours.palette.m3secondaryContainer : Colours.layer(Colours.palette.m3surfaceContainerHigh, 2)

                topLeftRadius: stateLayer.pressed ? Tokens.rounding.medium : isCurrentPage ? Tokens.rounding.extraLargeIncreased : isCategoryStart ? Tokens.rounding.extraLarge : Tokens.rounding.extraSmall
                topRightRadius: stateLayer.pressed ? Tokens.rounding.medium : isCurrentPage ? Tokens.rounding.extraLargeIncreased : isCategoryStart ? Tokens.rounding.extraLarge : Tokens.rounding.extraSmall
                bottomLeftRadius: stateLayer.pressed ? Tokens.rounding.medium : isCurrentPage ? Tokens.rounding.extraLargeIncreased : isCategoryEnd ? Tokens.rounding.extraLarge : Tokens.rounding.extraSmall
                bottomRightRadius: stateLayer.pressed ? Tokens.rounding.medium : isCurrentPage ? Tokens.rounding.extraLargeIncreased : isCategoryEnd ? Tokens.rounding.extraLarge : Tokens.rounding.extraSmall

                RadiusBehavior on topLeftRadius {}
                RadiusBehavior on topRightRadius {}
                RadiusBehavior on bottomLeftRadius {}
                RadiusBehavior on bottomRightRadius {}

                function activate(): void {
                    if (root.query.trim() || root.nState.pendingSearchRoute)
                        root.openResult(item.modelData);
                    else
                        root.nState.currentPageIdx = item.modelData.pageIndex;
                }

                // Windows (#210): nav entries take Tab focus like Nexus rows.
                // Enter/Space play the press ripple and open the page.
                activeFocusOnTab: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        event.accepted = true;
                        if (!event.isAutoRepeat) {
                            stateLayer.press(width / 2, height / 2);
                            item.activate();
                        }
                    }
                }
                Accessible.role: Accessible.Button
                Accessible.name: modelData.label
                Accessible.onPressAction: activate()
                onActiveFocusChanged: {
                    if (!activeFocus)
                        return;
                    // Keep the focused entry inside the scrolled list.
                    const min = -root.topMargin;
                    const max = Math.max(min, root.contentHeight + root.bottomMargin - root.height);
                    let to = root.contentY;
                    if (y - root.topMargin < to)
                        to = y - root.topMargin;
                    else if (y + height + root.bottomMargin > to + root.height)
                        to = y + height + root.bottomMargin - root.height;
                    root.contentY = Math.max(min, Math.min(max, to));
                }

                StateLayer {
                    id: stateLayer

                    anchors.fill: parent
                    topLeftRadius: parent.topLeftRadius
                    topRightRadius: parent.topRightRadius
                    bottomLeftRadius: parent.bottomLeftRadius
                    bottomRightRadius: parent.bottomRightRadius
                    stateOpacity: item.activeFocus ? 0.1 : containsMouse ? 0.08 : 0

                    onClicked: item.activate()
                }

                FocusRing {
                    showing: item.activeFocus
                    topLeftRadius: item.topLeftRadius
                    topRightRadius: item.topRightRadius
                    bottomLeftRadius: item.bottomLeftRadius
                    bottomRightRadius: item.bottomRightRadius
                }

                RowLayout {
                    id: layout

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.large
                    spacing: Tokens.spacing.medium

                    StyledRect {
                        Layout.fillHeight: true
                        Layout.topMargin: -1
                        Layout.bottomMargin: -1
                        implicitWidth: height

                        radius: Tokens.rounding.full
                        color: item.isCurrentPage ? Colours.palette.m3primary : Colours.palette.m3secondaryContainer

                        MaterialIcon {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: 1

                            text: item.modelData.icon
                            color: item.isCurrentPage ? Colours.palette.m3onPrimary : Colours.palette.m3onSecondaryContainer
                            fontStyle: Tokens.font.icon.builders.medium.weight(Font.Medium).build()
                            grade: 25
                            fill: item.modelData.noFill ? 0 : 1
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        StyledText {
                            Layout.fillWidth: true
                            text: item.modelData.label
                            font: Tokens.font.body.medium
                            elide: Text.ElideRight
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: item.modelData.description
                            color: Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.label.small
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.query.trim().length > 0 && root.results.length === 0
            text: Tr.tr("No matching settings")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.medium
            wrapMode: Text.Wrap
        }
    }

    component RadiusBehavior: Behavior {
        Anim {
            type: Anim.DefaultEffects
        }
    }
}
