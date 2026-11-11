import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services
import qs.modules.background

// Presentation placement for a running Wallpaper Engine that this profile has
// not opted into. A fresh profile keeps every background above foreign
// wallpaper children inside the desktop host. Existing profiles retain the
// released underlay policy. Replace must still avoid an above-icons embed
// while the engine runs.
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
            Wallpapers.sourceFresh = true;
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
            check(!nativeLayer.externalWallpaperEnabled,
                "a fresh disabled profile still yields to foreign wallpaper");
            check(!subject.underlayActive,
                "disabled integration still reports an underlay");
            check(subject.enabled && subject.screens.length === 1,
                "the own background was unmounted with integration disabled");
            check(subject.checkReady(screen),
                "the own background did not present with integration disabled");

            // These transitions must reconcile through the expression's
            // changed handler, without an explicit reconcileDesktop call.
            Wallpapers.sourceFresh = false;
            check(nativeLayer.externalWallpaperEnabled,
                "an existing disabled profile lost the released policy");
            check(subject.underlayActive, "an existing profile no longer yields to foreign wallpaper");
            Wallpapers.sourceFresh = true;
            check(!nativeLayer.externalWallpaperEnabled,
                "returning to a fresh disabled profile did not reconcile");
            WallpaperEngine.options = {enabled: true};
            check(nativeLayer.externalWallpaperEnabled,
                "enabled integration did not restore the released policy");
            check(subject.underlayActive, "enabled integration no longer yields to foreign wallpaper");
            // OFF/ON controls playback without replacing the foreign HWND.
            // The host drops coverage while stopped, then acknowledges the
            // same window again. A handback latch must not disable placement.
            WallpaperEngine.options = {enabled: false};
            check(!nativeLayer.externalWallpaperEnabled,
                "disabling integration did not restore the own background policy");
            nativeLayer.coveredByForeign = false;
            WallpaperEngine.options = {enabled: true};
            check(nativeLayer.externalWallpaperEnabled && !subject.underlayActive,
                "ON did not keep discovery enabled while playback resumed");
            nativeLayer.coveredByForeign = true;
            check(subject.underlayActive && WallpaperEngine.desktopClaimed
                && !WallpaperEngine.desktopHandedBack,
                "the same window did not regain its underlay acknowledgement");
            nativeLayer.coveredByForeign = false;
            check(WallpaperEngine.desktopHandedBack,
                "destroying the wallpaper window did not hand back");
            WallpaperEngine.applyStatus({detected: true, running: true, monitors: {}});
            check(WallpaperEngine.desktopHandedBack && !subject.externalActive,
                "a process-only status scan reclaimed a destroyed wallpaper");
            check(nativeLayer.externalWallpaperEnabled,
                "genuine handback disabled discovery of a later wallpaper");
            WallpaperEngine.options = {enabled: false};
            wallpaperEngine.running = false;
            check(!nativeLayer.externalWallpaperEnabled,
                "process liveness changed the integration policy");
            // With no process, externalActive stays false. Only the policy
            // changed handler can reconcile these setting/profile changes.
            WallpaperEngine.options = {enabled: true};
            check(nativeLayer.externalWallpaperEnabled,
                "enabling integration without a process did not reconcile");
            WallpaperEngine.options = {enabled: false};
            check(!nativeLayer.externalWallpaperEnabled,
                "disabling integration without a process did not reconcile");
            Wallpapers.sourceFresh = false;
            check(nativeLayer.externalWallpaperEnabled,
                "an existing profile without a process did not reconcile");
            Wallpapers.sourceFresh = true;
            check(!nativeLayer.externalWallpaperEnabled,
                "a fresh disabled profile without a process did not reconcile");
            wallpaperEngine.running = true;
            check(!nativeLayer.externalWallpaperEnabled,
                "a running process overrode disabled integration");

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
