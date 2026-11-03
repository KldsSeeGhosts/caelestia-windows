// Offscreen regression for #214: the live desktop stayed black after Wallpaper
// Engine handed it back even though the background window, its QML tree and a
// decodable wallpaper source were all present.
//
// WallpaperImpl changes `live.source` only after a ShaderEffectSource capture
// completes. While the background is covered by the engine's wallpaper window
// that capture can hold a black frame, and a capture scheduled just before the
// handback can complete after it. Either one sets transitionProgress back to 0
// and paints the capture over the verified wallpaper, which is the black field
// the live checks saw. The fixture drives the real WallpaperImpl (not a copy)
// through the handback while the window is hidden, through a capture that is
// still pending when the handback arrives, and through a zero-size layout that
// is resized, so all three regress here without Wallpaper Engine.
import QtQuick
import QtQuick.Window
import Quickshell
import qs.services
import "components/widgets"

ShellRoot {
    id: root

    settings.watchFiles: false

    property int assertions: 0
    property int step: 0
    property string fileA: Quickshell.shellPath("assets/wallpaper.webp")
    property string fileB: Quickshell.shellPath("assets/dino.png")
    property string fileC: Quickshell.shellPath("assets/wallpaper-handback.webp")
    property Item live: null
    property Item image: null
    property Item probeLive: null
    property Item probeImage: null

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function findLive(item): Item {
        for (const child of item.children) {
            if ("ready" in child && "playing" in child && "source" in child)
                return child;
            const nested = findLive(child);
            if (nested)
                return nested;
        }
        return null;
    }

    function findImage(item): Item {
        for (const child of item.children) {
            if ("status" in child && "sourceSize" in child)
                return child;
            const nested = findImage(child);
            if (nested)
                return nested;
        }
        return null;
    }

    function fail(error): void {
        console.error("CAELESTIA_WALLPAPER_IMPL_FAIL " + error);
        Qt.exit(1);
    }

    Window {
        id: win
        width: 360
        height: 240
        visible: true

        WallpaperImpl {
            id: impl
            objectName: "desktopWallpaper"
            anchors.fill: parent
            source: ""
        }

        // A background window can be laid out at zero size while its screen
        // geometry is applied. The source is applied directly at construction,
        // then the resize must make the Visual decode at display size instead
        // of holding the unusable zero-size image.
        Item {
            id: probeHost
            width: 0
            height: 0

            WallpaperImpl {
                id: probe
                anchors.fill: parent
                source: root.fileA
            }
        }
    }

    // Poll instead of sleeping a fixed time: the capture and image loads are
    // frame-driven, and a slow machine must not fail the state assertions.
    property int waitedMs: 0
    property int lastStep: -1
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            root.waitedMs += interval;
            if (root.lastStep !== root.step) {
                root.lastStep = root.step;
                console.log("CAELESTIA_WALLPAPER_IMPL_STEP", root.step,
                    "source", impl.source, "live", root.live ? root.live.source : "null",
                    "ready", root.live ? root.live.ready : false,
                    "progress", impl.transitionProgress);
            }
            if (root.waitedMs > 20000) {
                stop();
                root.fail("the wallpaper implementation did not settle at step " + root.step
                    + " (live " + (root.live ? root.live.source : "null")
                    + ", ready " + (root.live ? root.live.ready : false)
                    + ", progress " + impl.transitionProgress + ")");
                return;
            }
            try {
                root.advance();
            } catch (error) {
                stop();
                root.fail(error);
            }
        }
    }

    function advance(): void {
        if (root.step === 0) {
            root.live = root.findLive(impl);
            root.image = root.findImage(impl);
            root.probeLive = root.findLive(probe);
            root.probeImage = root.findImage(probe);
            root.check(root.live !== null, "the WallpaperImpl live visual is missing");
            root.check(root.image !== null, "the WallpaperImpl image is missing");
            root.check(root.probeLive !== null, "the zero-size live visual is missing");
            root.check(root.probeImage !== null, "the zero-size image is missing");
            impl.source = root.fileA;
            root.step = 1;
            return;
        }

        if (root.step === 1) {
            if (!(root.live.ready && impl.transitionProgress >= 1 && root.live.source === root.fileA))
                return;
            root.check(root.live.ready, "the first wallpaper did not decode");
            root.check(root.live.source === root.fileA, "the first wallpaper source was not applied");
            root.step = 2;
            return;
        }

        if (root.step === 2) {
            // The engine-era transition is still pending when the handback
            // arrives. That older capture must not complete into progress 0
            // over the verified source. Change B schedules the capture, then
            // the handback and change C happen in the same turn.
            WallpaperEngine.desktopHandedBack = false;
            impl.source = root.fileB;
            WallpaperEngine.desktopHandedBack = true;
            impl.source = root.fileC;
            root.check(root.live.source === root.fileC,
                "the handback source was not applied to live immediately");
            root.check(impl.transitionProgress === 1,
                "the handback left the transition covering the desktop");
            root.step = 3;
            return;
        }

        if (root.step === 3) {
            // Let the capture scheduled for B go away. It is stale and must
            // be ignored rather than set progress back to 0.
            if (!root.live.ready || root.live.source !== root.fileC)
                return;
            root.check(impl.transitionProgress === 1,
                "a capture scheduled before the handback covered the handback source");
            root.check(root.live.source === root.fileC, "the stale capture replaced the handback source");

            // The covered/unexposed case: the source changes while the window
            // cannot present a frame, then the window is revealed.
            win.visible = false;
            impl.source = root.fileA;
            root.check(root.live.source === root.fileA,
                "the handback source was not applied while the window was covered");
            root.check(impl.transitionProgress === 1,
                "the covered handback left the transition covering the desktop");
            win.visible = true;
            root.step = 4;
            return;
        }

        if (root.step === 4) {
            if (!root.live.ready || root.live.source !== root.fileA)
                return;
            root.check(impl.transitionProgress === 1,
                "the revealed handback window returned to a capture");
            // The own desktop (no handback) still crossfades through the
            // capture and settles on the new file.
            WallpaperEngine.desktopHandedBack = false;
            impl.source = root.fileB;
            root.step = 5;
            return;
        }

        if (root.step === 5) {
            if (!(root.live.ready && impl.transitionProgress >= 1 && root.live.source === root.fileB))
                return;
            root.check(root.live.source === root.fileB, "the ordinary transition did not reach its source");
            // The zero-size probe was painted once, then the layout gave it a
            // real size. Confirm the Visual reloaded the same decodeable local
            // file at display size instead of keeping a zero-size image.
            probeHost.width = 360;
            probeHost.height = 240;
            root.step = 6;
            return;
        }

        if (root.step === 6) {
            if (!(root.probeImage.status === Image.Ready && root.probeImage.sourceSize.width >= 256))
                return;
            root.check(root.probeLive.source === root.fileA, "the resize replaced the wallpaper source");
            root.check(root.probeLive.ready, "the resized wallpaper did not decode");
            root.check(root.probeImage.implicitWidth >= 256, "the resized image was not decoded at display size");
            console.log("CAELESTIA_WALLPAPER_IMPL_PASS " + root.assertions);
            Qt.exit(0);
        }
    }
}
