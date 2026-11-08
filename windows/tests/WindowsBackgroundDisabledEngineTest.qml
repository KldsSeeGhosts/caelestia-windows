import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services
import qs.modules.background

// Presentation placement for a running Wallpaper Engine that this profile has
// not opted into. The adapter shows the bundled source, but the pinned
// backend places every marked background below a visible foreign child and
// refuses an above-icons embed while one exists. The fallback therefore stays
// mounted in the underlay position and presents there; it cannot cover the
// engine's window without a backend change. Replace is the strongest case
// because that mode otherwise embeds above the icons.
Item {
    id: root

    property WindowsBackground subject: WindowsBackground { id: subject }
    property var environmentValues: ({
        CAELESTIA_WINDOWS_BACKGROUND: "1",
        CAELESTIA_WINDOWS_DESKTOP_ICONS: "Replace"
    })
    onEnvironmentValuesChanged: Quickshell.environment = environmentValues
    readonly property var nativeLayer: Native.DesktopLayer
    readonly property var wallpaperEngine: WallpaperEngine
    readonly property var wallpapers: Wallpapers
    property ShellScreen screen: ShellScreen {}
    property var screensCatalog: []
    onScreensCatalogChanged: { Screens.screens = screensCatalog; Quickshell.screens = screensCatalog; }
    property QtObject clock: QtObject {
        property real width: 240
        property real height: 80
    }
    property QtObject wallpaperItem: QtObject {
        property string source: root.wallpapers.current
        property real transitionProgress: 1
    }
    property QtObject backgroundWindow: QtObject {
        property var modelData: root.screen
        property bool visible: true
        property real width: 1920
        property real height: 1080
        property QtObject contentItem: QtObject {
            property QtObject desktopClock: root.clock
            property QtObject desktopWallpaper: root.wallpaperItem
        }
    }

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            Quickshell.environment = environmentValues;
            WallpaperEngine.options = {enabled: false};
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}};
            screensCatalog = [screen];
            subject.instances = [backgroundWindow];
            nativeLayer.active = true;
            // The backend sees the disabled engine's visible wallpaper window.
            nativeLayer.coveredByForeign = true;
            subject.reconcileDesktop();

            check(!subject.externalActive, "the disabled engine became the visible source");
            check(Wallpapers.current === Wallpapers.fallback,
                "the disabled engine replaced the bundled source");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "the disabled engine supplied the palette source");
            check(nativeLayer.aboveIcons.length === 0,
                "a running disabled engine was covered from an above-icons embed");
            check(subject.underlayActive,
                "the fallback was not left in the underlay position");
            check(subject.enabled && subject.screens.length === 1,
                "the fallback was unmounted instead of presented beneath the engine");
            check(subject.checkReady(screen),
                "the fallback did not present beneath the running disabled engine");

            // The above-icons placement is safe again only once no foreign
            // wallpaper window can be covered.
            nativeLayer.coveredByForeign = false;
            wallpaperEngine.running = false;
            subject.reconcileDesktop();
            check(!subject.underlayActive, "a stopped engine still claims the underlay");
            check(nativeLayer.aboveIcons.length === 1
                && nativeLayer.aboveIcons[0] === "caelestia-background",
                "Replace did not resume above the icons after the engine stopped");
            check(subject.enabled && subject.screens.length === 1,
                "the own desktop was not mounted after the engine stopped");

            console.log("CAELESTIA_BACKGROUND_DISABLED_ENGINE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_BACKGROUND_DISABLED_ENGINE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
