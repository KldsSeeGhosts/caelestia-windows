import QtQuick
import Caelestia.Config
import qs.components
import qs.modules.nexus

// Windows adaptation of modules/nexus/Pages.qml.
//
// The upstream page container destroys the current page and incubates the next
// one asynchronously. On Windows the detached Nexus window can be closed (or
// switched to another page) while that incubation is still outstanding; when it
// completes, upstream's callback writes `currentItem` on the destroyed
// container and dereferences its anchors. Qt reports this as
//   Invalid write to global property "currentItem"
// followed by null dereferences while the window tears down.
//
// Each load here owns a small token. Replacing the page or destroying the
// container invalidates every older token, and a late completion destroys the
// object it produced instead of touching the dead container or root. The page
// components, ordering, animation and `nState` contract are unchanged.
Item {
    id: root

    required property NexusState nState

    property int lastPageIdx
    property int animOff
    property Item currentItem

    // Tokens for incubations that have not settled yet. Written only on the
    // page-container side; the completion closure reads its own token, never
    // `root`, after the container has been destroyed.
    property var pageTokens: []

    function invalidatePages(): void {
        for (const token of (root.pageTokens ?? []))
            token.alive = false;
        root.pageTokens = [];
    }

    function loadPage(idx: int): void {
        if (root.destroying)
            return;

        root.invalidatePages();
        if (root.currentItem) {
            root.currentItem.destroy();
            root.currentItem = null;
        }

        const comp = PageCompRegistry.pageComps[idx] ?? PageCompRegistry.placeholderComp;
        const incubator = comp.incubateObject(container, {
            nState: root.nState
        });
        const token = {
            alive: true
        };
        root.pageTokens = [token];

        const attach = () => {
            if (!token.alive) {
                // The page was replaced or the window is gone. Dispose of the
                // stale result here; it must not reach the dead container.
                if (incubator.status === Component.Ready && incubator.object)
                    incubator.object.destroy();
                return;
            }
            if (incubator.status !== Component.Ready || !incubator.object)
                return;
            incubator.object.anchors.fill = container;
            root.currentItem = incubator.object;
        };

        if (incubator.status === Component.Ready)
            attach();
        else
            incubator.onStatusChanged = status => {
                if (status === Component.Ready)
                    attach();
            };
    }

    property bool destroying: false

    Component.onDestruction: {
        root.destroying = true;
        root.invalidatePages();
    }

    Item {
        id: container

        objectName: "PageContainer"
        anchors.fill: parent
        layer.enabled: opacity < 1
        Component.onCompleted: root.loadPage(root.nState.currentPageIdx)
    }

    Connections {
        function onCurrentPageIdxChanged(): void {
            switchAnim.complete();
            root.animOff = root.Tokens.padding.extraLarge * (root.nState.currentPageIdx > root.lastPageIdx ? 1 : -1);
            switchAnim.start();
            root.lastPageIdx = root.nState.currentPageIdx;
        }

        target: root.nState
    }

    SequentialAnimation {
        id: switchAnim

        Anim {
            target: container
            property: "opacity"
            to: 0
            type: Anim.DefaultEffects
        }
        ScriptAction {
            script: root.loadPage(root.nState.currentPageIdx)
        }
        PropertyAction {
            target: container.anchors
            property: "topMargin"
            value: root.animOff
        }
        PropertyAction {
            target: container.anchors
            property: "bottomMargin"
            value: -root.animOff
        }
        ParallelAnimation {
            Anim {
                target: container
                property: "opacity"
                from: 0
                to: 1
                type: Anim.SlowEffects
            }
            Anim {
                target: container.anchors
                properties: "topMargin,bottomMargin"
                to: 0
                type: Anim.SlowEffects
            }
        }
    }
}
