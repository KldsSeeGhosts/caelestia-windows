// Reproduction for #214 on the background content. The live warning
// "QQuickItem: Cannot use same item on different windows at the same time"
// comes from the wallpaper item (WallpaperImpl's live Visual) being carried
// from an old QQuickWindow to the new one while an effect outside the moved
// subtree still references it. On the next frame Qt crashes in
// QQuickWindowPrivate::dirtyItem.
//
// The stray ShaderEffectSource below stands in for that non-moving effect
// (the window-level layer capture seen in the live crash). It is parented to
// the old window's root and sources the wallpaper image. Once the background
// owns its wallpaper per window, detaching the content destroys the old
// wallpaper, the stray source is released, and the recreated window builds a
// fresh one. Without that ownership the same item moves to the second window,
// Qt warns, and the fixture fails.
import QtQuick
import QtQuick.Window
import Quickshell
import Caelestia
import qs.modules.background
import qs.services

ShellRoot {
    id: root

    settings.watchFiles: false

    Background { id: bg }
    Window { id: winB; width: 800; height: 800; visible: true }

    property Item content: null
    property Item oldWallpaper: null
    property Item oldLive: null
    property Item stray: null
    property int assertions: 0
    property int waitedMs: 0
    property int stage: 0

    FontLoader { source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function windowOf(item): var {
        return item ? item.Window.window : null;
    }
    function fail(error): void {
        console.error("CAELESTIA_BACKGROUND_SHARED_FAIL " + error);
        Qt.exit(1);
    }

    Component {
        id: strayComponent

        ShaderEffectSource {
            live: false
            visible: false
        }
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            root.waitedMs += interval;
            if (root.waitedMs > 15000) {
                stop();
                root.fail("the background wallpaper did not load");
            }
            if (bg.instances.length < 1)
                return;
            root.content = bg.instances[0].contentItem;
            const wallpaper = CUtils.findChild(root.content, "desktopWallpaper");
            if (!wallpaper)
                return;
            if (root.stage === 0) {
                root.stage = 1;
                stop();
                try {
                    root.oldWallpaper = wallpaper;
                    // WallpaperImpl order: capture1, capture2, Visual (live),
                    // layer source, transition.
                    root.oldLive = wallpaper.children[2];
                    check(root.oldLive !== null, "the wallpaper image exists");
                    // A capture owned by the old window, not by the moved
                    // background item tree.
                    root.stray = strayComponent.createObject(windowOf(wallpaper).contentItem);
                    check(root.stray !== null, "the window-owned capture is created");
                    root.stray.sourceItem = root.oldLive;
                    check(windowOf(root.stray.sourceItem) === windowOf(root.content),
                        "the stray capture starts on the background window");
                    settle.start();
                } catch (error) {
                    root.fail(error);
                }
            }
        }
    }
    // Let the loaded wallpaper settle before moving the tree.
    Timer {
        id: settle
        interval: 300
        onTriggered: {
            try {
                check(root.oldWallpaper !== null, "the wallpaper is still present before the move");
                // The backend detaches the content item and attaches it to
                // the recreated window. The old window remains alive while
                // its replacement is created, exactly like the live crash.
                root.content.parent = null;
                root.content.parent = winB.contentItem;
                moved.start();
            } catch (error) {
                root.fail(error);
            }
        }
    }
    // The replacement wallpaper is loaded asynchronously.
    Timer {
        id: moved
        interval: 100
        repeat: true
        onTriggered: {
            root.waitedMs += interval;
            if (root.waitedMs > 30000) {
                stop();
                root.fail("the recreated background did not load its wallpaper");
            }
            const wallpaper = CUtils.findChild(root.content, "desktopWallpaper");
            if (!wallpaper || windowOf(wallpaper) !== winB)
                return;
            stop();
            try {
                check(root.content.parent === winB.contentItem,
                    "the background follows the recreated window");
                check(wallpaper !== root.oldWallpaper,
                    "the recreated window builds its own wallpaper");
                check(root.oldWallpaper === null,
                    "the old wallpaper is unloaded rather than moved");
                check(root.stray.sourceItem === null,
                    "the window-owned capture releases the old wallpaper");
                check(windowOf(wallpaper) === winB,
                    "the new wallpaper belongs to the new window only");
                check(root.oldLive === null || windowOf(root.oldLive) !== winB,
                    "the old wallpaper image is not on the new window");
                renderTurn.start();
            } catch (error) {
                root.fail(error);
            }
        }
    }
    // A render turn after the move surfaces deferred ownership failures.
    Timer {
        id: renderTurn
        interval: 300
        onTriggered: {
            try {
                check(windowOf(CUtils.findChild(root.content, "desktopWallpaper")) === winB,
                    "the new wallpaper stays on the new window after a render turn");
                console.log("CAELESTIA_BACKGROUND_SHARED_PASS " + root.assertions);
                Qt.quit();
            } catch (error) {
                root.fail(error);
            }
        }
    }
}
