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
    // backend contract: an embedded WorkerW window with no insert-after, no
    // icons embedding, no refused SetParent and a visible foreign wallpaper
    // window still inside the host is the underlay. When that window leaves,
    // the acknowledgement drops even though the host stays embedded (#220).
    property QtObject underlaySupportedHost: QtObject {
        property bool embedRefused: false
        property bool coveredByForeign: false
        property bool underlayActive: enabled && !embedRefused && aboveIcons.length === 0
            && coveredByForeign
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
    property QtObject wallpaperEngine: QtObject {
        property bool running: false
        property int scans: 0
        function refresh(deep): void { scans++ }
    }
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
    // UNDERLAY_HANDLER
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
            reconcileDesktop();
            screensCatalog = [screen, secondScreen];
            instances = [backgroundWindow];
            nativeLayer = root.underlaySupportedHost;
            nativeLayer.active = true;
            check(underlaySupported, "feature detection finds the backend property");
            check(!underlayActive, "own desktop has no foreign wallpaper window");
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

            // A supporting backend starts fail-closed too: a detected process
            // is only an ownership claim until the backend finds its window.
            nativeLayer = root.underlaySupportedHost;
            check(underlaySupported && !underlayActive, "supporting backend starts without an acknowledgement");
            check(externalActive, "startup detects the engine process");
            check(!hostEnabled, "startup yields to the unacknowledged process");
            check(screens.length === 0, "startup yield mounts no background screens");

            // A refused SetParent leaves the window top level. The backend
            // must deny the acknowledgement before the shell stops yielding,
            // even with a foreign wallpaper window in the host.
            nativeLayer.embedRefused = true;
            nativeLayer.coveredByForeign = true;
            check(!underlayActive, "refused embed denies the underlay");
            check(!hostEnabled, "refused embed yields");
            check(screens.length === 0, "refused embed fails closed");
            nativeLayer.embedRefused = false;
            check(underlaySupported && underlayActive, "supporting backend acknowledges the foreign owner");
            check(hostEnabled, "accepted embed restores the underlay");
            check(screens.length === 2, "accepted embed mounts every screen");

            // A refusal after that acknowledgement is not a handback. The
            // refused panel stays top level, so the adapter must withdraw the
            // claim and unmount instead of keeping a full-screen background
            // over applications.
            wallpaperEngine.scans = 0;
            nativeLayer.embedRefused = true;
            check(!underlayActive, "a refusal after the acknowledgement drops the underlay");
            check(embedRefused, "the adapter sees the refused embed");
            check(externalActive, "the engine process still runs during the refusal");
            check(!desktopClaimed, "the refused embed withdraws the desktop claim");
            check(!hostEnabled, "the refused embed fails closed");
            check(screens.length === 0, "the refused embed unmounts every screen");
            check(wallpaperEngine.scans === 1, "the refused embed re-scans the owner");
            check(checkReady(screen), "the refused embed reports a released desktop");
            nativeLayer.embedRefused = false;
            check(underlayActive, "an accepted re-embed restores the underlay");
            check(desktopClaimed, "an accepted re-embed restores the claim");
            check(hostEnabled && screens.length === 2, "an accepted re-embed remounts every screen");

            // A non-empty above-icons embed also denies the acknowledgement
            // and unmounts rather than covering the external wallpaper.
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
            nativeLayer.coveredByForeign = true;
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

            // The external wallpaper window can leave the host while the
            // process scan still sees wallpaper64.exe. The backend drops the
            // acknowledgement; that is the #220 handback, so the process no
            // longer owns the desktop and the adapter restores its own
            // background instead of yielding an unowned desktop (#214).
            wallpaperEngine.scans = 0;
            nativeLayer.coveredByForeign = false;
            check(!underlayActive, "the backend drops the underlay acknowledgement at handback");
            check(externalActive, "the engine process keeps running after the handback");
            check(wallpaperEngine.scans === 1, "the handback requests an immediate owner re-scan");
            check(hostEnabled, "the handback restores the background host");
            check(screens.length === 2, "the handback remounts every background screen");
            check(instances.length === 1 && instances[0] === backgroundWindow,
                "the handback has its own background instances");
            check(checkReady(screen), "the handback background presents over the desktop host");
            console.log("CAELESTIA_BACKGROUND_HANDBACK_STATE", JSON.stringify({
                external: externalActive, underlay: underlayActive,
                host: hostEnabled, screens: screens.length, instances: instances.length
            }));

            // A new engine process starts fail-closed again: its wallpaper
            // must be discovered as the underlay before the shell yields.
            wallpapers.externalWallpaperActive = false;
            check(hostEnabled && screens.length === 2, "the stopped process keeps the handback background mounted");
            wallpapers.externalWallpaperActive = true;
            check(externalActive && !underlayActive, "a new process starts unacknowledged");
            check(!hostEnabled && screens.length === 0, "a new process fails closed before discovery");

            // With the owner confirmed gone, the same backend state mounts the
            // background in the visible, non-underlay position.
            wallpapers.externalWallpaperActive = false;
            check(!underlayActive && !externalActive, "the handback has no external owner");
            check(hostEnabled && screens.length === 2, "the handback remounts the visible background");
            check(checkReady(screen), "the handback background is ready");

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
