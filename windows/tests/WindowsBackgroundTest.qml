import QtQuick

// Exercises the WindowsBackground underlay state machine without Quickshell.
// The runner splices the real property/function blocks from the adapter, so
// this fixture only supplies the backend, service and screen mocks below.
Item {
    id: root

    // Quickshell.env reads the environment once and returns strings. The
    // fixture keeps the same contract over a replaceable map.
    property QtObject environment: QtObject {
        function env(name): string { return String(root.environmentValues[name] ?? ""); }
    }
    property var environmentValues: ({
        CAELESTIA_WINDOWS_BACKGROUND: "1",
        CAELESTIA_WINDOWS_DESKTOP_ICONS: "Behind"
    })

    // The two backend shapes the adapter must support. The current runtime has
    // no underlayActive property; the feature-detected shape acknowledges the
    // embed after DesktopHost discovers WorkerW.
    property QtObject underlaySupportedHost: QtObject {
        property bool underlayActive: false
        property bool active: false
        property bool enabled: false
        property var aboveIcons: []
    }
    property QtObject legacyHost: QtObject {
        property bool active: false
        property bool enabled: false
        property var aboveIcons: []
    }
    property var nativeLayer: root.underlaySupportedHost

    property QtObject wallpapers: QtObject {
        property bool externalWallpaperActive: false
        property string current: "file:///wallpaper.png"
    }
    property QtObject wallpaperEngine: QtObject { property bool running: false }
    property QtObject globalConfig: QtObject {
        function forScreen(name): var { return root.screenConfig; }
    }
    property QtObject screenConfig: QtObject {
        property QtObject background: QtObject {
            property QtObject desktopClock: QtObject { property bool enabled: true }
        }
    }
    property QtObject cutils: QtObject {
        function findChild(item, name): var {
            return item === null || item === undefined ? null : (item[name] ?? null);
        }
    }

    property var screens: []
    property var instances: []
    property var screen: ({ name: "FixtureScreen" })
    property QtObject clock: QtObject {
        property real width: 240
        property real height: 80
    }
    property QtObject wallpaperItem: QtObject {
        property string source: "file:///wallpaper.png"
        property real transitionProgress: 1
    }
    property QtObject windowContent: QtObject {
        property QtObject desktopClock: root.clock
        property QtObject desktopWallpaper: root.wallpaperItem
    }
    property QtObject backgroundWindow: QtObject {
        property var modelData: root.screen
        property bool visible: true
        property real width: 1920
        property real height: 1080
        property QtObject contentItem: root.windowContent
    }

    // WINDOWS_BACKGROUND_PROPERTIES
    // RECONCILE_DESKTOP
    // CHECK_READY

    property int assertions: 0

    function check(value, description): void {
        assertions++;
        if (!value) throw new Error(description);
    }

    function restoreEnvironment(): void {
        environmentValues = ({
            CAELESTIA_WINDOWS_BACKGROUND: "1",
            CAELESTIA_WINDOWS_DESKTOP_ICONS: "Behind"
        });
    }

    Component.onCompleted: {
        try {
            // The ordinary desktop, before any external owner exists. The
            // shared readiness contract must still work without an underlay.
            instances = [backgroundWindow];
            nativeLayer.active = true;
            check(!underlayActive, "no underlay before the backend acknowledges one");
            check(checkReady(screen), "own desktop presents the ready background");
            nativeLayer.active = false;
            instances = [];

            // The opt-in gate owns both mounting and host discovery.
            check(backgroundRequested, "background requested from the environment");
            check(desktopIcons === "Behind", "icons default to behind");
            check(hostEnabled, "requested background hosts its own desktop");
            check(underlaySupported, "feature detection finds the backend property");
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "0" });
            check(!backgroundRequested && !hostEnabled, "environment gate disables the host");
            restoreEnvironment();
            check(backgroundRequested && hostEnabled, "environment gate restores the host");

            // A backend without the acknowledgement keeps the fail-closed yield.
            nativeLayer = root.legacyHost;
            check(!underlaySupported && !underlayActive, "legacy backend has no underlay");
            wallpapers.externalWallpaperActive = true;
            check(!hostEnabled, "legacy backend yields to an external owner");

            // A supporting backend mounts the window while it discovers WorkerW,
            // then keeps it mounted once the embed is acknowledged.
            nativeLayer = root.underlaySupportedHost;
            check(underlaySupported && !underlayActive, "supporting backend reports no embed yet");
            check(!hostEnabled, "supporting backend yields until the embed is acknowledged");
            nativeLayer.underlayActive = true;
            check(underlayActive, "acknowledged embed is observed");
            check(hostEnabled, "acknowledged underlay hosts over the external owner");

            // Host discovery must be reconciled from the request, not just from
            // the window lifetime, so the first scan can find WorkerW.
            nativeLayer.enabled = false;
            nativeLayer.aboveIcons = ["stale"];
            reconcileDesktop();
            check(nativeLayer.enabled, "reconcile enables the desktop host");
            check(nativeLayer.aboveIcons.length === 0, "icons stay behind by default");

            // The Replace setting embeds the background above the icon view.
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "1", CAELESTIA_WINDOWS_DESKTOP_ICONS: "Replace" });
            check(desktopIcons === "Replace", "icons override from the environment");
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 1 && nativeLayer.aboveIcons[0] === "caelestia-background",
                "replace icons embed the background");
            restoreEnvironment();
            reconcileDesktop();

            // A legacy backend is disabled under an external owner and enabled
            // again once the owner stops.
            nativeLayer = root.legacyHost;
            wallpapers.externalWallpaperActive = true;
            nativeLayer.enabled = true;
            reconcileDesktop();
            check(!nativeLayer.enabled, "legacy reconcile disables the host under an external owner");
            wallpapers.externalWallpaperActive = false;
            reconcileDesktop();
            check(nativeLayer.enabled, "legacy reconcile hosts its own desktop");

            // Requesting the background off always releases the host.
            nativeLayer = root.underlaySupportedHost;
            nativeLayer.underlayActive = true;
            nativeLayer.enabled = true;
            wallpapers.externalWallpaperActive = true;
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "0" });
            reconcileDesktop();
            check(!nativeLayer.enabled, "requested-off reconcile releases the host");
            restoreEnvironment();

            // Underlay readiness uses the ordinary presentation contract.
            nativeLayer.underlayActive = true;
            nativeLayer.active = true;
            wallpaperEngine.running = true;
            instances = [backgroundWindow];
            check(checkReady(screen), "underlay presents the ready background");
            backgroundWindow.visible = false;
            check(!checkReady(screen), "hidden underlay is not ready");
            backgroundWindow.visible = true;
            wallpaperItem.transitionProgress = 0.5;
            check(!checkReady(screen), "transitioning underlay is not ready");
            wallpaperItem.transitionProgress = 1;
            wallpaperItem.source = "";
            check(!checkReady(screen), "missing underlay wallpaper is not ready");
            wallpaperItem.source = "file:///wallpaper.png";
            clock.width = 0;
            check(!checkReady(screen), "unsized clock is not ready");
            clock.width = 240;
            screenConfig.background.desktopClock.enabled = false;
            windowContent.desktopClock = null;
            check(checkReady(screen), "disabled and absent clock is ready");
            screenConfig.background.desktopClock.enabled = true;
            check(!checkReady(screen), "enabled clock requires the clock");
            windowContent.desktopClock = clock;
            nativeLayer.active = false;
            check(!checkReady(screen), "inactive desktop host is not ready");
            nativeLayer.active = true;
            instances = [];
            check(!checkReady(screen), "absent background window is not ready");
            instances = [backgroundWindow];
            wallpaperEngine.running = false;
            check(checkReady(screen), "underlay readiness does not depend on process discovery");
            wallpaperEngine.running = true;

            // The external owner may stop before the backend releases the
            // embed. The same window stays ready across that handoff.
            wallpapers.externalWallpaperActive = false;
            check(underlayActive, "underlay acknowledgement survives the owner stopping");
            check(checkReady(screen), "underlay stays ready across the owner stopping");

            // Without the acknowledgement the adapter must yield, and a
            // supporting backend may yield even while its host is active.
            wallpapers.externalWallpaperActive = true;
            nativeLayer.underlayActive = false;
            check(!hostEnabled, "yield disables the background windows");
            screens = [];
            nativeLayer.active = false;
            check(checkReady(screen), "yield with the desktop host inactive");
            nativeLayer.active = true;
            check(checkReady(screen), "supporting backend yields with the host active");
            screens = [screen];
            check(!checkReady(screen), "yield requires an empty background screen set");
            screens = [];

            // A legacy backend cannot yield while its host is active: that
            // would leave its wallpaper mounted over the external owner.
            nativeLayer = root.legacyHost;
            nativeLayer.active = true;
            check(!checkReady(screen), "legacy backend cannot yield over an active host");
            nativeLayer.active = false;
            check(checkReady(screen), "legacy backend yields when its host is inactive");

            console.log("CAELESTIA_BACKGROUND_UNDERLAY_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_BACKGROUND_UNDERLAY_FAIL " + error);
            Qt.exit(1);
        }
    }
}
