pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia
import Caelestia.Components
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.components.filedialog
import qs.services
import qs.utils
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/wallandstyle/WallpaperSelect.qml.
//
// Upstream imports Caelestia.Models for the FileSystemEntry type and walks
// `Wallpapers.list` sub-directories into category pages. The portable Windows
// build excludes the Models module (AppDb/FileSystemModel need SQL and the
// excluded app store), and the staged Windows Wallpapers facade scans one flat
// directory plus Wallpaper Engine projects. The layout, cards, motion and the
// featured wallpaper are upstream; the entries are plain objects normalized by
// the facade, so the type annotation is dropped and categories are only shown
// when the facade reports one. "Random" calls the facade's own picker instead
// of the Linux `caelestia wallpaper -r` process.
PageBase {
    id: root

    readonly property var localWalls: Wallpapers.list.filter(w => Wallpapers.getCategoryFor(w) === "")
    readonly property var categories: {
        const seen = ({});
        for (const w of Wallpapers.list) {
            const category = Wallpapers.getCategoryFor(w);
            if (category && !seen[category])
                seen[category] = w;
        }
        return Object.values(seen);
    }

    title: Tr.tr("Wallpapers")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.small

        ButtonRow {
            Layout.bottomMargin: Tokens.spacing.medium
            Layout.alignment: Qt.AlignHCenter
            spacing: Tokens.spacing.small

            IconTextButton {
                icon: "photo_library"
                text: Tr.tr("Browse")
                font: Tokens.font.body.large
                isRound: true
                shapeMorph: true
                horizontalPadding: Tokens.padding.extraLarge
                verticalPadding: Tokens.padding.medium
                onClicked: browseDialog.open()

                FileDialog {
                    id: browseDialog

                    title: Tr.tr("Select an image")
                    filterLabel: Tr.tr("Image files")
                    filters: Images.validImageExtensions
                    nameFilters: [Tr.tr("Image files") + " (*." + Images.validImageExtensions.join(" *.") + ")"]
                    onAccepted: {
                        // The native dialog's accepted() has no path argument.
                        // Convert its QUrl to a native path (UNC included) and
                        // ignore a cancel/empty selection instead of passing
                        // undefined to the facade.
                        if (!selectedFile || String(selectedFile).length === 0)
                            return;
                        const path = CUtils.toLocalFile(selectedFile);
                        if (path.length === 0)
                            return;
                        Wallpapers.setWallpaper(path);
                        root.nState.closeSubPage();
                    }
                }
            }

            IconTextButton {
                icon: "shuffle"
                text: Tr.tr("Random")
                font: Tokens.font.body.large
                isRound: true
                shapeMorph: true
                horizontalPadding: Tokens.padding.extraLarge
                verticalPadding: Tokens.padding.medium
                type: IconTextButton.Tonal
                onClicked: {
                    Wallpapers.setRandom();
                    root.nState.closeSubPage();
                }
            }
        }

        WallItem {
            imgHeight: Math.round(width * 0.3)
            radius: Tokens.rounding.extraLarge
            source: Quickshell.shellPath("assets/wallpaper.webp")
            text: Tr.tr("Featured wallpaper")
            fillLabel: false
            onClicked: {
                Wallpapers.setWallpaper(Quickshell.shellPath("assets/wallpaper.webp"));
                root.nState.closeSubPage();
            }
        }

        StyledText {
            Layout.topMargin: Tokens.spacing.large
            text: Tr.tr("Local wallpapers")
            font: Tokens.font.title.small
        }

        GridLayout {
            Layout.fillWidth: true
            visible: grid.count > 0

            columns: Config.nexus.wallpapersPerRow
            rowSpacing: Tokens.spacing.medium
            columnSpacing: Tokens.spacing.large

            Repeater {
                id: grid

                model: {
                    const list = [...root.localWalls];
                    list.sort((a, b) => a.name.localeCompare(b.name));
                    while (list.length < Config.nexus.wallpapersPerRow)
                        list.push(null);
                    return list;
                }

                WallItem {
                    required property var modelData

                    // Empty placeholders for sizing
                    opacity: modelData ? 1 : 0
                    enabled: modelData

                    // Wallpaper Engine entries carry a project.json `path` for
                    // selection and a real image in `preview`. Feed the preview
                    // to the tile, as the launcher adapter does, so Qt never
                    // tries to decode project.json as an image.
                    source: !modelData ? "" : modelData.preview ? "file:///" + modelData.preview : modelData.engine ? "" : String(modelData.path ?? "")
                    text: modelData?.name ?? ""
                    onClicked: {
                        Wallpapers.setWallpaper(modelData.path);
                        root.nState.closeSubPage();
                    }
                }
            }
        }

        // Category rows only exist when the facade reports a sub-directory,
        // which the flat Windows scan never does. Kept so an engine provider
        // that later reports categories still renders upstream's behaviour.
        ColumnLayout {
            Layout.fillWidth: true
            visible: root.categories.length > 0
            spacing: Tokens.spacing.extraSmall / 2

            Repeater {
                model: root.categories

                NavRow {
                    id: categoryRow

                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    first: categoryRow.index === 0
                    last: categoryRow.index === root.categories.length - 1
                    icon: "folder"
                    text: Wallpapers.getCategoryFor(categoryRow.modelData)
                    trailingIcon: "chevron_right"
                    onClicked: {
                        root.nState.selectedWallpaperCategory = Wallpapers.getCategoryFor(categoryRow.modelData);
                        root.nState.openSubPage(2); // Category page
                    }
                }
            }
        }

        Loader {
            Layout.fillWidth: true

            asynchronous: true
            active: grid.count === 0
            visible: active

            sourceComponent: StyledRect {
                color: Colours.tPalette.m3surfaceContainer
                radius: Tokens.rounding.extraLarge
                implicitHeight: noWallsLayout.implicitHeight + Tokens.padding.extraExtraLarge * 2

                ColumnLayout {
                    id: noWallsLayout

                    anchors.centerIn: parent
                    spacing: Tokens.spacing.extraSmall

                    MaterialIcon {
                        Layout.alignment: Qt.AlignHCenter
                        text: "hide_image"
                        color: Colours.palette.m3outline
                        fontStyle: Tokens.font.icon.extraLarge
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: Tr.tr("No local wallpapers found")
                        color: Colours.palette.m3outline
                        font: Tokens.font.title.small
                    }
                }
            }
        }
    }
}
