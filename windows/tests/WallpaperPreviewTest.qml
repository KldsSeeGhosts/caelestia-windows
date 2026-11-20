import QtQuick
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services

QtObject {
    id: root

    property int assertions: 0
    property int previousWrites: 0
    readonly property var highlightedPalette: ({
        name: "dynamic", mode: "light", colours: {primary: "ae5a81", surface: "f8edf2"},
        windowsSurfaceTint: {surface: "fae0ed"}
    })
    property Connections previewRequests: Connections {
        target: SchemeGenerator
        function onPreviewCallsChanged(): void {
            Qt.callLater(root.answerPreview);
        }
    }
    function check(value, message): void {
        assertions++;
        if (!value) throw new Error(message);
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            WallpaperEngine.options = {enabled: false};
            Wallpapers.files = [
                {path: "C:/walls/local.jpg", onDisk: true},
                {path: "C:/walls/cloud.jpg", onDisk: false}
            ];
            Wallpapers.previewEntry(Wallpapers.list[0]);
            check(Wallpapers.showPreview && Wallpapers.current === "C:/walls/local.jpg", "local preview");
            Wallpapers.previewEntry(Wallpapers.list[1]);
            check(!Wallpapers.showPreview, "placeholder stops previous preview");
            check(Wallpapers.current === Wallpapers.currentImage, "placeholder leaves desktop unchanged");
            check(Wallpapers.previewPath !== "C:/walls/cloud.jpg", "placeholder not stored");
            Wallpapers.preview("C:/walls/cloud.jpg");
            check(!Wallpapers.showPreview && Wallpapers.current !== "C:/walls/cloud.jpg", "direct preview cannot hydrate");
            Native.FsUtils.existingFiles.push("C:/walls/cloud.jpg");
            check(Wallpapers.setWallpaper("C:/walls/cloud.jpg"), "explicit open accepted");
            check(Native.Wallpaper.calls.length === 1 && Native.Wallpaper.calls[0] === "C:/walls/cloud.jpg", "native apply recorded");
            check(Wallpapers.list[1].onDisk, "successful open marks placeholder local");
            Wallpapers.previewEntry(Wallpapers.list[1]);
            check(Wallpapers.showPreview && Wallpapers.current === "C:/walls/cloud.jpg", "opened placeholder previews");

            Native.FsUtils.existingFiles.push("C:/walls/local.jpg");
            check(Colours.current.m3surface.toString() !== "#121312", "fixture starts with the fixed palette");
            SchemeGenerator.schemeChanged({
                name: "dynamic", mode: "dark", source: "C:/walls/cloud.jpg",
                colours: {primary: "95d3c0", surface: "121312"},
                windowsSurfaceTint: {surface: "041b14"}
            });
            previousWrites = SchemeGenerator.runs;
            check(!Colours.tintWallpaperSurfaces && Colours.palette.m3surface.toString() === "#121312",
                "saved palette defaults to the upstream surface");
            Wallpapers.previewEntry(Wallpapers.list[0]);
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_PREVIEW_FAIL " + error);
            Qt.exit(1);
        }
    }

    function answerPreview(): void {
        try {
            const calls = SchemeGenerator.previewCalls;
            if (calls.length === 1) {
                check(calls[0].path === "C:/walls/local.jpg" && calls[0].smart,
                    "only the latest eligible highlight requests a preview");
                Wallpapers.previewEntry(Wallpapers.list[1]);
                SchemeGenerator.previewReady(calls[0].request, highlightedPalette);
                check(!Colours.showPreview && Colours.palette === Colours.current,
                    "a superseded preview reply cannot paint");
                return;
            }
            check(calls.length === 2 && calls[1].path === "C:/walls/cloud.jpg",
                "the worker receives the new highlight");
            SchemeGenerator.previewReady(calls[1].request, highlightedPalette);
            check(Colours.showPreview && Colours.light && !Colours.currentLight,
                "the shell uses the preview mode without changing the saved mode");
            check(Colours.palette.m3primary.toString() === "#ae5a81"
                && Colours.current.m3primary.toString() === "#95d3c0", "preview colours stay separate");
            check(Colours.palette.m3surface.toString() === "#f8edf2", "preview defaults to the upstream surface");
            GlobalConfig.windows = {keep: true};
            Colours.setWallpaperSurfaceTint(true);
            check(Colours.tintWallpaperSurfaces && GlobalConfig.windows.keep, "setting keeps other Windows options");
            check(Colours.palette.m3surface.toString() === "#fae0ed"
                && Colours.current.m3surface.toString() === "#041b14", "opt-in tint applies to both palettes");
            check(Colours.palette.m3primary.toString() === "#ae5a81", "tint leaves accents alone");
            Colours.setWallpaperSurfaceTint(false);
            Wallpapers.stopPreview();
            SchemeGenerator.previewReady(calls[1].request, highlightedPalette);
            check(!Colours.showPreview && !Colours.light && Colours.palette.m3surface.toString() === "#121312",
                "closing the picker restores the saved colours and ignores a late reply");
            check(Native.Wallpaper.calls.length === 1 && SchemeGenerator.runs === previousWrites,
                "browsing did not apply a wallpaper or save a scheme");
            console.log("CAELESTIA_WALLPAPER_PREVIEW_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_PREVIEW_FAIL " + error);
            Qt.exit(1);
        }
    }
}
