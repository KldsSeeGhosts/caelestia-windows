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
// FloatingWindow is platform-independent in Quickshell: on Windows it is an
// ordinary top-level window with native per-monitor DPI. The Windows tiler
// never manages it because the backend refuses every window owned by the shell
// process (tiling_scope.cpp: "The shell never tiles itself, whatever the
// allowlist says"), so no extra exclusion rule is needed here.
Singleton {
    id: root

    function create(parent: Item, props: var): var {
        return nexusComp.createObject(parent ?? dummy, props);
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

            color: Colours.tPalette.m3surface
            surfaceFormat.opaque: false

            onVisibleChanged: {
                if (!visible)
                    destroy();
            }

            implicitWidth: nexus.implicitWidth
            implicitHeight: nexus.implicitHeight

            minimumSize.width: contentItem.Tokens.sizes.nexus.minWidth
            minimumSize.height: contentItem.Tokens.sizes.nexus.minHeight

            contentItem.Config.screen: screen.name
            contentItem.Tokens.screen: screen.name

            title: Tr.tr("Nexus — %1").arg(PageRegistry.pages[nexus.nState.currentPageIdx].label)

            Nexus {
                id: nexus

                anchors.fill: parent
                nState.screen: win.screen
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
