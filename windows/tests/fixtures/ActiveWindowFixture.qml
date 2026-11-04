import QtQuick
import Quickshell
import qs.modules.bar.popouts as Popouts
import qs.services

ShellRoot {
    id: root

    property int step: 0
    property real expectedWidth
    property real expectedHeight
    property real lastAnimatedWidth: 0
    property real upstreamHeight

    function check(condition, message) {
        if (!condition) {
            console.error("ACTIVE_WINDOW_FIXTURE_FAIL " + message);
            Qt.exit(1);
        }
    }

    function findPreview(item) {
        if (item.objectName === "activeWindowPreview")
            return item;
        for (const child of item.children) {
            const found = findPreview(child);
            if (found)
                return found;
        }
        return null;
    }

    Popouts.PopoutState {
        id: state
    }

    Window {
        visible: true
        width: 800
        height: 700

        Popouts.ActiveWindow {
            id: content
            popouts: state
        }

        // The default remains the upstream, capture-sized layout.
        Popouts.ActiveWindowContent {
            id: upstreamContent
            popouts: state
        }

        // Stand-in for the wrapper's animated geometry in an offscreen window.
        Item {
            id: animated
            property bool open: false
            width: open ? content.implicitWidth : 0
            height: open ? content.implicitHeight : 0
            Behavior on width { NumberAnimation { duration: 1000 } }
            Behavior on height { NumberAnimation { duration: 1000 } }
        }
    }

    Timer {
        running: true
        repeat: true
        interval: 50
        onTriggered: {
            const preview = root.findPreview(content);
            const upstreamPreview = root.findPreview(upstreamContent);
            if (root.step === 0) {
                Hypr.activeToplevel = { title: "Editor", lastIpcObject: { class: "fixture" }, wayland: null };
                animated.open = true;
            } else if (root.step === 1) {
                root.expectedWidth = content.implicitWidth;
                root.expectedHeight = content.implicitHeight;
                root.check(root.expectedWidth > 0 && root.expectedHeight > 0, "initial size");
                root.check(preview.objectName === "activeWindowPreview", "preview lookup");
                root.upstreamHeight = upstreamContent.implicitHeight;
                // Simulate the backend's first frame dimensions arriving.
                preview.implicitWidth = 400;
                preview.implicitHeight = 225;
                upstreamPreview.implicitWidth = 400;
                upstreamPreview.implicitHeight = 225;
            } else if (root.step === 2) {
                root.check(content.implicitWidth === root.expectedWidth && content.implicitHeight === root.expectedHeight, "first frame resized popout");
                root.check(upstreamContent.implicitHeight !== root.upstreamHeight, "upstream layout no longer follows capture");
                console.log("ACTIVE_WINDOW_FIXTURE_SIZES upstreamBefore=" + root.upstreamHeight
                    + " upstreamAfter=" + upstreamContent.implicitHeight
                    + " reserved=" + root.expectedWidth + "x" + root.expectedHeight);
                // Source replacement resets size before a portrait frame arrives.
                preview.implicitWidth = 0;
                preview.implicitHeight = 0;
                Hypr.activeToplevel = { title: "A long title ".repeat(50), lastIpcObject: { class: "other" }, wayland: null };
            } else if (root.step === 3) {
                root.check(content.implicitWidth === root.expectedWidth && content.implicitHeight === root.expectedHeight, "source change resized popout");
                preview.implicitWidth = 120;
                preview.implicitHeight = 225;
            } else if (root.step === 4) {
                root.check(content.implicitWidth === root.expectedWidth && content.implicitHeight === root.expectedHeight, "portrait frame resized popout");
                Hypr.activeToplevel = null;
            } else if (root.step === 5) {
                root.check(content.implicitWidth === root.expectedWidth && content.implicitHeight === root.expectedHeight, "missing source resized popout");
                root.check(animated.width > 0 && animated.width < root.expectedWidth, "opening animation not in progress");
                animated.open = false;
            } else if (root.step === 7) {
                root.check(animated.width < root.lastAnimatedWidth, "closing animation did not progress");
                root.check(content.implicitWidth === root.expectedWidth && content.implicitHeight === root.expectedHeight, "close resized content");
                console.log("ACTIVE_WINDOW_FIXTURE_PASS");
                Qt.quit();
            }
            if (root.step > 0 && root.step < 5) {
                root.check(animated.width >= root.lastAnimatedWidth, "opening animation reversed");
            }
            if (root.step > 0) {
                root.lastAnimatedWidth = animated.width;
            }
            root.step++;
        }
    }
}
