import QtQuick

// Exercises the WindowsBackground underlay state machine without Quickshell.
// The runner splices the real property, screen and function blocks from the
// adapter, so this fixture only supplies the backend and service mocks below.
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
    // no underlayActive property. The feature-detected shape mirrors the
    // backend contract: an embedded WorkerW window with no insert-after and no
    // icons embedding is the underlay, so aboveIcons decides it here.
    property QtObject underlaySupportedHost: QtObject {
        property bool underlayActive: aboveIcons.length === 0
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

    // The real screens binding filters this catalog, so the yield and mount
    // paths are exercised through the production expression.
    property var screen: ({ name: "FixtureScreen" })
    property var secondScreen: ({ name: "SecondScreen" })
    property var screensCatalog: []
    property bool smoke: false
    property int screenIndex: 0
    property var quickshellScreens: root.screensCatalog

    property var instances: []
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
    // WINDOWS_BACKGROUND_SCREENS
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
            // The real screens expression expands the catalog on our own
            // desktop and closes when the host is not embedded.
            screensCatalog = [screen, secondScreen];
            instances = [backgroundWindow];
            nativeLayer = root.underlaySupportedHost;
            nativeLayer.active = true;
            check(underlaySupported, "feature detection finds the backend property");
            check(underlayActive, "an empty icon embed is the underlay");
            check(!externalActive, "no external owner yet");
            check(backgroundRequested && hostEnabled, "requested background hosts its own desktop");
            check(desktopIcons === "Behind", "icons default to behind");
            check(screens.length === 2, "own desktop mounts every screen");
            check(checkReady(screen), "own desktop presents the ready background");
            nativeLayer.active = false;
            check(screens.length === 0, "inactive desktop host mounts no screens");
            check(!checkReady(screen), "inactive own desktop is not ready");
            nativeLayer.active = true;

            // The opt-in gate owns both screens and host discovery.
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "0" });
            check(!backgroundRequested && !hostEnabled, "environment gate disables the host");
            check(screens.length === 0, "environment gate unmounts the screens");
            restoreEnvironment();
            check(backgroundRequested && hostEnabled && screens.length === 2, "environment gate restores the host");

            // A backend without the acknowledgement keeps the fail-closed yield.
            nativeLayer = root.legacyHost;
            check(!underlaySupported && !underlayActive, "legacy backend has no underlay");
            wallpapers.externalWallpaperActive = true;
            check(externalActive, "external owner observed");
            check(!hostEnabled, "legacy backend yields to an external owner");
            check(screens.length === 0, "legacy yield unmounts the screens");

            // A supporting backend acknowledges the empty-icon embed and keeps
            // the windows mounted over the external owner.
            nativeLayer = root.underlaySupportedHost;
            check(underlaySupported && underlayActive, "supporting backend acknowledges the empty-icon embed");
            check(hostEnabled, "acknowledged underlay hosts over the external owner");
            check(screens.length === 2, "acknowledged underlay mounts every screen");
            nativeLayer.aboveIcons = ["caelestia-background"];
            check(!underlayActive, "an above-icons embed is not an underlay");
            check(!hostEnabled, "supporting backend yields without the underlay");
            check(screens.length === 0, "unacknowledged underlay fails closed");
            nativeLayer.aboveIcons = [];
            check(underlayActive && hostEnabled && screens.length === 2, "clearing the embed restores the underlay");

            // Host discovery must be reconciled from the request, not just from
            // the window lifetime, so the first scan can find WorkerW.
            nativeLayer.enabled = false;
            nativeLayer.aboveIcons = ["stale"];
            reconcileDesktop();
            check(nativeLayer.enabled, "reconcile enables the desktop host");
            check(nativeLayer.aboveIcons.length === 0, "icons stay behind by default");
            check(underlayActive, "reconcile keeps the empty-icon underlay");

            // Replace embeds above the icon view, but never while an external
            // owner is active: that embedding would cover the WorkerW underlay.
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "1", CAELESTIA_WINDOWS_DESKTOP_ICONS: "Replace" });
            check(desktopIcons === "Replace", "icons override from the environment");
            nativeLayer.aboveIcons = ["stale"];
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0, "replace icons never embed over an external owner");
            check(underlayActive, "external replace keeps the underlay acknowledged");
            check(hostEnabled && screens.length === 2, "external replace keeps the screens mounted");

            // The same Replace setting embeds above the icons on our own
            // desktop, which is not an underlay.
            wallpapers.externalWallpaperActive = false;
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 1 && nativeLayer.aboveIcons[0] === "caelestia-background",
                "replace icons embed on the own desktop");
            check(!underlayActive, "above-icons embedding is not the underlay");
            check(hostEnabled && screens.length === 2, "own desktop mounts screens above icons");
            check(checkReady(screen), "own desktop above the icons is ready");

            // Starting an external owner must withdraw that embedding even
            // while the underlay keeps the host enabled. The fixture drives the
            // reconciler directly; the changed handler is checked statically.
            wallpapers.externalWallpaperActive = true;
            check(externalActive, "external owner transition observed");
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0 && underlayActive,
                "external owner transition withdraws the above-icons embed");
            check(hostEnabled && screens.length === 2, "external owner transition keeps the screens mounted");
            restoreEnvironment();
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0 && underlayActive, "behind icons restores the underlay");

            // A legacy backend is disabled under an external owner and enabled
            // again once the owner stops.
            nativeLayer = root.legacyHost;
            nativeLayer.enabled = true;
            reconcileDesktop();
            check(!nativeLayer.enabled, "legacy reconcile disables the host under an external owner");
            wallpapers.externalWallpaperActive = false;
            reconcileDesktop();
            check(nativeLayer.enabled, "legacy reconcile hosts its own desktop");

            // Requesting the background off always releases the host.
            nativeLayer = root.underlaySupportedHost;
            nativeLayer.aboveIcons = [];
            nativeLayer.enabled = true;
            wallpapers.externalWallpaperActive = true;
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "0" });
            reconcileDesktop();
            check(!nativeLayer.enabled, "requested-off reconcile releases the host");
            restoreEnvironment();
            check(underlayActive && hostEnabled && screens.length === 2, "requested background restores the underlay");

            // Underlay readiness uses the ordinary presentation contract.
            nativeLayer = root.underlaySupportedHost;
            nativeLayer.aboveIcons = [];
            nativeLayer.active = true;
            wallpapers.externalWallpaperActive = true;
            wallpaperEngine.running = true;
            instances = [backgroundWindow];
            check(hostEnabled && underlayActive, "underlay mounts over the external owner");
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
            check(hostEnabled && screens.length === 2, "background stays mounted across the owner stopping");
            check(checkReady(screen), "underlay stays ready across the owner stopping");

            // Without the acknowledgement the adapter must yield. A non-empty
            // above-icons embed is what distinguishes that state, and the real
            // screens expression must fail closed.
            wallpapers.externalWallpaperActive = true;
            nativeLayer.aboveIcons = ["caelestia-background"];
            check(!underlayActive, "above-icons embed denies the underlay");
            check(!hostEnabled, "unacknowledged underlay yields");
            check(screens.length === 0, "non-empty above-icons fails closed while external");
            nativeLayer.active = false;
            check(checkReady(screen), "yield with the desktop host inactive");
            nativeLayer.active = true;
            check(checkReady(screen), "supporting backend yields with the host active");

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
