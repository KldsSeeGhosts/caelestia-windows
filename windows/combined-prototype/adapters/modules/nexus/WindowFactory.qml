pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.nexus

// Windows adaptation of modules/nexus/WindowFactory.qml.
//
// The upstream FloatingWindow, its colour behaviour, minimum size, per-monitor
// Config/Tokens screen binding, title and destroy-on-close lifecycle are kept
// exactly. Two things are added for the Windows entry points:
//
//   * `openPage(idx)` lets the bar popout's detached mode and the utilities
//     toggle open the window on the page they asked for. Upstream passes the
//     page through the inline overlay's NexusState; the standalone window has
//     no such channel, so the page travels as a component property instead.
//   * nothing else differs. Callers that use upstream `create()` still get the
//     default page.
//
// The window is tracked while it lives. A page can be incubating when the
// window is destroyed, and the smoke gate needs to close every window it opened
// before it reports PASS; `windowCount`/`closeAll()` make that observable
// without a second ownership registry in the test.
//
// FloatingWindow is platform-independent in Quickshell: on Windows it is an
// ordinary top-level window with native per-monitor DPI. The Windows tiler
// never manages it because the backend refuses every window owned by the shell
// process (tiling_scope.cpp: "The shell never tiles itself, whatever the
// allowlist says"), so no extra exclusion rule is needed here.
Singleton {
    id: root

    property var windows: []

    readonly property int windowCount: root.windows.length

    function create(parent: Item, props: var): var {
        const win = nexusComp.createObject(parent ?? dummy, props);
        if (win)
            root.windows = [...root.windows, win];
        return win;
    }

    function forget(win): void {
        if (root.windows.indexOf(win) >= 0)
            root.windows = root.windows.filter(item => item !== win);
    }

    // Used by the smoke gate. Destroying directly also covers a window that was
    // created and closed again before its first show, where visible=false would
    // not change and therefore would not trigger the destroy-on-close handler.
    function closeAll(): void {
        for (const win of [...root.windows]) {
            if (win)
                win.destroy();
        }
    }

    function openPage(pageIdx: int): void {
        root.create(null, {
            pageIdx: pageIdx
        });
    }

    QtObject {
        id: dummy
    }

    Component {
        id: nexusComp

        FloatingWindow {
            id: win

            // Local Windows addition: the starting Nexus page. Bound below so it
            // is in place before the page container loads.
            property int pageIdx: 0

            // A closing window can lose `screen` before its content is gone.
            // Keep the last real screen so the per-monitor Config/Tokens
            // bindings and the upstream pages never dereference null during
            // teardown.
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

            color: Colours.tPalette.m3surface
            surfaceFormat.opaque: false

            onVisibleChanged: {
                if (!visible)
                    destroy();
            }

            implicitWidth: nexus.implicitWidth
            implicitHeight: nexus.implicitHeight

            minimumSize.width: contentItem?.Tokens?.sizes?.nexus?.minWidth ?? 0
            minimumSize.height: contentItem?.Tokens?.sizes?.nexus?.minHeight ?? 0

            contentItem.Config.screen: (win.screen ?? win.lastScreen)?.name ?? ""
            contentItem.Tokens.screen: (win.screen ?? win.lastScreen)?.name ?? ""

            title: {
                const idx = nexus?.nState?.currentPageIdx ?? win.pageIdx;
                return Tr.tr("Nexus — %1").arg(PageRegistry.pages[idx]?.label ?? "");
            }

            Nexus {
                id: nexus

                anchors.fill: parent
                nState.screen: win.screen ?? win.lastScreen
                nState.isWindow: true
                nState.currentPageIdx: win.pageIdx
                onClose: win.destroy()
            }

            Behavior on color {
                CAnim {}
            }
        }
    }
}
