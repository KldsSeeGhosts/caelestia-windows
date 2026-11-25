pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.windowinfo

// Windows floating-window entry point for modules/windowinfo. Upstream only
// shows the inspector as a detached bar popout, which depends on the Wayland
// focus grab and overlay lifecycle. On Windows the inspector is an ordinary
// FloatingWindow, following the reviewed Nexus factory lifecycle: repeated
// requests reuse the live window, replace its client, restore it if minimized
// and request activation while the caller still owns foreground rights.
Singleton {
    id: root

    property var windows: []
    readonly property int windowCount: root.windows.length

    function activeWindow(): var {
        for (let i = root.windows.length - 1; i >= 0; --i) {
            const win = root.windows[i];
            if (win && win.visible)
                return win;
        }
        return null;
    }

    function openForClient(client): var {
        if (!client)
            return null;
        const existing = root.activeWindow();
        if (existing) {
            existing.client = client;
            existing.minimized = false;
            existing.requestActivate();
            return existing;
        }
        const win = infoComp.createObject(dummy, { client: client });
        if (win) {
            root.windows = [...root.windows, win];
            win.requestActivate();
        }
        return win;
    }

    function forget(win): void {
        if (root.windows.indexOf(win) >= 0)
            root.windows = root.windows.filter(item => item !== win);
    }

    function closeAll(): void {
        const closing = [...root.windows];
        // FloatingWindow destruction is queued by the engine. The registry is
        // owned here rather than by that deferred teardown, so smoke shutdown
        // can observe closure deterministically; the later destruction handler
        // simply finds nothing to remove.
        root.windows = [];
        for (const win of closing) {
            if (win)
                win.destroy();
        }
    }

    QtObject {
        id: dummy
    }

    Component {
        id: infoComp

        FloatingWindow {
            id: win

            property var client: null
            property var lastScreen: null

            Component.onCompleted: {
                if (screen)
                    lastScreen = screen;
            }
            Component.onDestruction: root.forget(win)
            onScreenChanged: {
                if (screen)
                    lastScreen = screen;
            }
            onVisibleChanged: {
                if (!visible)
                    destroy();
            }

            title: Tr.tr("Window info")
            color: Colours.tPalette.m3surface
            surfaceFormat.opaque: false

            // The content is created only after FloatingWindow has a screen.
            // Creating it in the initial binding pass can evaluate the
            // screen-attached Tokens once with no screen and leave type-conversion
            // diagnostics behind even after the real screen arrives.
            implicitWidth: infoLoader.item?.implicitWidth ?? 1024
            implicitHeight: infoLoader.item?.implicitHeight ?? 576

            contentItem.Config.screen: (win.screen ?? win.lastScreen)?.name ?? ""
            contentItem.Tokens.screen: (win.screen ?? win.lastScreen)?.name ?? ""

            Loader {
                id: infoLoader

                anchors.fill: parent
                active: (win.screen ?? win.lastScreen) !== null

                sourceComponent: WindowInfo {
                    anchors.fill: parent
                    screen: win.screen ?? win.lastScreen
                    client: win.client
                }
            }

            Behavior on color {
                CAnim {}
            }
        }
    }
}
