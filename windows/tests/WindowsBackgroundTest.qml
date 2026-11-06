import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services
import qs.modules.background

// Complete production WindowsBackground and WallpaperEngine, with recording
// native singletons and a fake screen-instance factory. No production source
// is extracted or rewritten.
Item {
    id: root

    property WindowsBackground subject: WindowsBackground { id: subject }
    property var environmentValues: ({
        CAELESTIA_WINDOWS_BACKGROUND: "1",
        CAELESTIA_WINDOWS_DESKTOP_ICONS: "Behind"
    })
    onEnvironmentValuesChanged: Quickshell.environment = environmentValues
    readonly property var nativeLayer: Native.DesktopLayer
    readonly property var wallpaperEngine: WallpaperEngine
    readonly property var wallpapers: Wallpapers
    readonly property var screenConfig: GlobalConfig.screenConfig
    property ShellScreen screen: ShellScreen {}
    property ShellScreen secondScreen: ShellScreen { name: "SecondScreen" }
    property var screensCatalog: []
    onScreensCatalogChanged: { Screens.screens = screensCatalog; Quickshell.screens = screensCatalog; }
    property alias instances: subject.instances
    property QtObject clock: QtObject {
        property real width: 240
        property real height: 80
    }
    property QtObject wallpaperItem: QtObject {
        property string source: root.wallpapers.current
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

    readonly property bool underlaySupported: subject.underlaySupported
    readonly property bool underlayActive: subject.underlayActive
    readonly property bool externalActive: subject.externalActive
    readonly property bool backgroundRequested: subject.backgroundRequested
    readonly property bool hostEnabled: subject.enabled
    readonly property bool embedRefused: subject.embedRefused
    readonly property string desktopIcons: subject.desktopIcons
    readonly property var screens: subject.screens
    function reconcileDesktop(): void { subject.reconcileDesktop(); }
    function checkReady(screen): bool { return subject.checkReady(screen); }

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

    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            Quickshell.environment = environmentValues;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "file:///we-preview.png"}};
            // The real screens expression expands the catalog on our own
            // desktop and closes when the host is not embedded.
            reconcileDesktop();
            screensCatalog = [screen, secondScreen];
            instances = [backgroundWindow];
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

            wallpaperEngine.running = true;
            check(externalActive, "external owner observed");

            // #146 regression: a detected process is only an ownership claim
            // until the backend finds its window. That is not a reason to
            // unmount the fallback: the shell desktop has to be mounted
            // beneath the engine already when its first frame arrives, or the
            // hand-off exposes the Windows wallpaper. Both monitors keep their
            // fallback window and the backend pins them below any visible
            // foreign child; nothing here predicts a rendered frame.
            check(underlaySupported && !underlayActive, "supporting backend starts without an acknowledgement");
            check(hostEnabled, "the unacknowledged process keeps the fallback mounted");
            check(screens.length === 2, "both monitors keep the fallback before the first external frame");
            check(checkReady(screen), "the fallback presents beneath the unacknowledged engine");
            check(nativeLayer.aboveIcons.length === 0, "the fallback embeds below the icons, not over the engine");

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
            wallpaperEngine.status = "ready";
            nativeLayer.embedRefused = true;
            check(!underlayActive, "a refusal after the acknowledgement drops the underlay");
            check(embedRefused, "the adapter sees the refused embed");
            check(externalActive, "the engine process still runs during the refusal");
            check(!wallpaperEngine.desktopClaimed, "the refused embed withdraws the desktop claim");
            check(!hostEnabled, "the refused embed fails closed");
            check(screens.length === 0, "the refused embed unmounts every screen");
            check(wallpaperEngine.status === "unavailable", "the refused embed re-scans the owner");
            check(checkReady(screen), "the refused embed reports a released desktop");
            nativeLayer.embedRefused = false;
            check(underlayActive, "an accepted re-embed restores the underlay");
            check(wallpaperEngine.desktopClaimed, "an accepted re-embed restores the claim");
            check(hostEnabled && screens.length === 2, "an accepted re-embed remounts every screen");

            // A stale above-icons embed while an external owner is active is a
            // configuration the reconciler withdraws; it must not unmount the
            // fallback. An unmount there would expose the Windows wallpaper
            // until the next embed, and the backend already refuses to
            // acknowledge the underlay through a non-empty aboveIcons.
            nativeLayer.aboveIcons = ["caelestia-background"];
            check(!underlayActive, "an above-icons embed is not an underlay");
            check(hostEnabled && screens.length === 2, "a stale above-icons embed keeps the fallback mounted");
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0, "reconcile withdraws the above-icons embed");
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
            wallpaperEngine.running = false;
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 1 && nativeLayer.aboveIcons[0] === "caelestia-background",
                "replace icons embed on the own desktop");
            check(!underlayActive, "above-icons embedding is not the underlay");
            check(hostEnabled && screens.length === 2, "own desktop mounts screens above icons");
            check(checkReady(screen), "own desktop above the icons is ready");

            // Starting an external owner must withdraw that embedding even
            // while the underlay keeps the host enabled. The fixture drives the
            // reconciler as well as the production changed handler.
            wallpaperEngine.running = true;
            check(externalActive, "external owner transition observed");
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0 && underlayActive,
                "external owner transition withdraws the above-icons embed");
            check(hostEnabled && screens.length === 2, "external owner transition keeps the screens mounted");
            restoreEnvironment();
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0 && underlayActive, "behind icons restores the underlay");

            // Requesting the background off always releases the host.
            nativeLayer.aboveIcons = [];
            nativeLayer.coveredByForeign = true;
            nativeLayer.enabled = true;
            wallpaperEngine.running = true;
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "0" });
            reconcileDesktop();
            check(!nativeLayer.enabled, "requested-off reconcile releases the host");
            restoreEnvironment();
            check(underlayActive && hostEnabled && screens.length === 2, "requested background restores the underlay");

            // Underlay readiness uses the ordinary presentation contract.
            nativeLayer.aboveIcons = [];
            nativeLayer.active = true;
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
            // Restore the production source binding after the missing-source
            // case so the handback checks the visible wallpaper path.
            wallpaperItem.source = Qt.binding(function() { return root.wallpapers.current; });
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

            // A same-process wallpaper return in Replace mode (#214 P2).
            // Configure Replace while the underlay is acknowledged, close the
            // wallpaper without stopping wallpaper64.exe, then reopen it. The
            // handback must leave the background in the underlay position: the
            // backend's underlayActive getter requires an empty aboveIcons, so
            // a replace embed would prevent the returning wallpaper from ever
            // being acknowledged and the handback latch could never clear.
            environmentValues = ({ CAELESTIA_WINDOWS_BACKGROUND: "1", CAELESTIA_WINDOWS_DESKTOP_ICONS: "Replace" });
            check(desktopIcons === "Replace", "replace icons configured before the same-process return");
            check(underlayActive && externalActive, "replace keeps the acknowledged underlay");
            check(nativeLayer.aboveIcons.length === 0, "replace does not embed above an acknowledged wallpaper");

            nativeLayer.coveredByForeign = false;
            check(!underlayActive && !externalActive, "the replace handback releases the external claim");
            check(wallpaperEngine.desktopHandedBack, "the replace handback keeps the latch while the process runs");
            check(nativeLayer.aboveIcons.length === 0, "the replace handback does not cover the returning engine");
            check(hostEnabled && screens.length === 2, "the replace handback mounts the own desktop");
            check(wallpapers.current === wallpapers.fileCurrent, "the replace handback shows the own wallpaper");

            nativeLayer.coveredByForeign = true;
            check(underlayActive, "a wallpaper reopened by the same process is acknowledged");
            check(externalActive && !wallpaperEngine.desktopHandedBack, "the reopened wallpaper reclaims the desktop");
            check(wallpapers.currentImage === "file:///we-preview.png", "the reclaim supplies the engine preview for colour generation");
            check(wallpapers.current === wallpapers.handbackWallpaper,
                "the reclaimed engine never replaces the retained local underlay with its preview");
            check(hostEnabled && screens.length === 2, "the reclaim keeps the host and screens");
            check(nativeLayer.aboveIcons.length === 0, "the reclaim keeps the underlay position");

            // Replace returns to the own desktop once the process is gone, so
            // the guard must not permanently withdraw the icons embed.
            wallpaperEngine.running = false;
            check(nativeLayer.aboveIcons.length === 1 && nativeLayer.aboveIcons[0] === "caelestia-background",
                "replace embeds above the icons once the process stops");

            // Restore the acknowledged, running state the default handback
            // case below starts from.
            restoreEnvironment();
            nativeLayer.coveredByForeign = true;
            wallpaperEngine.running = true;
            check(underlayActive && externalActive && !wallpaperEngine.desktopHandedBack,
                "the behind-icons underlay is restored for the default handback");

            // The external wallpaper window can leave the host while the
            // process scan still sees wallpaper64.exe. That is a genuine
            // handback: the backend drops the acknowledgement, the ownership
            // guard releases the external claim, and the shell shows its own
            // wallpaper and clock instead of an unowned WorkerW (#214).
            wallpaperEngine.status = "ready";
            nativeLayer.coveredByForeign = false;
            check(!underlayActive, "the backend drops the underlay acknowledgement at handback");
            check(!externalActive, "the handback releases the external claim");
            check(wallpaperEngine.status === "unavailable", "the handback requests an immediate owner re-scan");
            check(hostEnabled, "the handback restores the background host");
            check(screens.length === 2, "the handback remounts every background screen");
            check(instances.length === 1 && instances[0] === backgroundWindow,
                "the handback has its own background instances");
            check(checkReady(screen), "the handback background presents over the desktop host");
            check(wallpapers.current === wallpapers.fileCurrent,
                "the handback shows the shell's own wallpaper, not the external preview");
            console.log("CAELESTIA_BACKGROUND_HANDBACK_STATE", JSON.stringify({
                external: externalActive, underlay: underlayActive,
                host: hostEnabled, screens: screens.length, instances: instances.length,
                ownWallpaper: wallpapers.current === wallpapers.fileCurrent
            }));

            // A new engine process starts unacknowledged, and its wallpaper
            // must be discovered as the underlay. The fallback already waits
            // beneath it: nothing is unmounted while that discovery runs.
            wallpaperEngine.running = false;
            check(hostEnabled && screens.length === 2, "the stopped process keeps the handback background mounted");
            wallpaperEngine.running = true;
            check(externalActive && !underlayActive, "a new process starts unacknowledged");
            check(hostEnabled && screens.length === 2, "a new process keeps the fallback beneath it");
            check(checkReady(screen), "the fallback presents while the new process is unacknowledged");

            // With the owner confirmed gone, the same backend state mounts the
            // background in the visible, non-underlay position.
            wallpaperEngine.running = false;
            check(!underlayActive && !externalActive, "the handback has no external owner");
            check(hostEnabled && screens.length === 2, "the handback remounts the visible background");
            check(checkReady(screen), "the handback background is ready");

            // A stale above-icons embed is withdrawn instead of unmounting the
            // fallback. The screens expression only closes when the desktop
            // host itself is unavailable, because a panel that cannot be
            // embedded would sit over the applications.
            wallpaperEngine.running = true;
            nativeLayer.aboveIcons = ["caelestia-background"];
            nativeLayer.coveredByForeign = true;
            check(!underlayActive, "above-icons embed denies the underlay");
            check(hostEnabled && screens.length === 2, "above-icons keeps the fallback mounted");
            reconcileDesktop();
            check(nativeLayer.aboveIcons.length === 0 && underlayActive, "reconcile restores the beneath-engine underlay");
            nativeLayer.active = false;
            check(screens.length === 0, "an unavailable desktop host mounts no fallback window");
            check(!checkReady(screen), "an unavailable desktop host is not ready");
            nativeLayer.active = true;
            check(hostEnabled && screens.length === 2 && checkReady(screen), "the fallback presents once the host returns");

            console.log("CAELESTIA_BACKGROUND_UNDERLAY_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_BACKGROUND_UNDERLAY_FAIL " + error);
            Qt.exit(1);
        }
    }
}
