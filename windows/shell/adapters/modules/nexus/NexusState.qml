import QtQuick
import Quickshell

// Windows adaptation of modules/nexus/NexusState.qml.
//
// Upstream types `selectedBtDevice` as BluetoothDevice from
// Quickshell.Bluetooth. The pinned Windows backend does not build the BlueZ
// module (`BLUETOOTH` defaults to `${QS_POSIX_DEFAULT}` and is forced off for
// WIN32 in quickshell/CMakeLists.txt), so that import cannot resolve here.
// The Nexus Bluetooth pages read the staged WindowsBluetooth facade instead of
// a Quickshell.Bluetooth device, therefore the selection stays untyped.
//
// `selectedApp` is upstream's `DesktopEntry`; it is left untyped for the same
// reason a selection crossing adapters should not depend on a module the page
// never imports. Search navigation also waits for the active page instance.
QtObject {
    id: root

    property ShellScreen screen
    property bool isWindow
    property bool animatingContainer
    property int currentPageIdx
    property list<int> subPageIdxStack
    property bool searchOpen
    property var activePage: null
    property var pendingSearchRoute: null

    property string selectedWallpaperCategory
    // Undefined means all displays. Explicit choices retain the physical
    // identity, so disconnecting/replacing a display cannot retarget a pick.
    property var wallpaperTarget: undefined
    property var selectedBtDevice
    property var selectedApp
    property int editingVpnIndex: -1
    property string selectedNetworkSsid
    property string selectedNetworkId
    property string selectedEthernetInterface
    property bool networkDetailsFromSaved

    signal close
    signal subPageOpened(idx: int)
    signal subPageClosed

    function samePath(left, right): bool {
        if (!left || left.length !== right.length)
            return false;
        for (let i = 0; i < right.length; ++i) {
            if (left[i] !== right[i])
                return false;
        }
        return true;
    }

    function searchNavigate(pageIndex: int, path): void {
        if (root.pendingSearchRoute?.pageIndex === pageIndex
                && root.samePath(root.pendingSearchRoute.path, path))
            return;
        if (!root.pendingSearchRoute && root.activePage
                && root.currentPageIdx === pageIndex
                && root.samePath(root.subPageIdxStack, path))
            return;

        root.pendingSearchRoute = { pageIndex: pageIndex, path: Array.from(path) };
        if (root.currentPageIdx !== pageIndex) {
            root.activePage = null;
            root.currentPageIdx = pageIndex;
        } else if (root.activePage) {
            root.applySearchRoute();
        }
    }

    function applySearchRoute(): void {
        const route = root.pendingSearchRoute;
        if (!route || !root.activePage || route.pageIndex !== root.currentPageIdx)
            return;
        root.pendingSearchRoute = null;
        if (root.samePath(root.subPageIdxStack, route.path))
            return;
        while (root.subPageIdxStack.length)
            root.closeSubPage();
        for (const idx of route.path)
            root.openSubPage(idx);
    }

    function openSubPage(idx: int): void {
        if (!root.subPageIdxStack)
            root.subPageIdxStack = [];
        root.subPageIdxStack.push(idx);
        root.subPageOpened(idx);
    }

    function closeSubPage(): void {
        if (!root.subPageIdxStack || root.subPageIdxStack.length === 0)
            return;
        root.subPageClosed();
        root.subPageIdxStack.pop();
    }

    // A window can be destroyed while a page or StackView binding is still
    // settling. Guard the stack so a late currentPageIdx write cannot dereference
    // a destroyed list.
    onCurrentPageIdxChanged: {
        if (root.pendingSearchRoute && root.pendingSearchRoute.pageIndex !== root.currentPageIdx)
            root.pendingSearchRoute = null;
        if (root.subPageIdxStack)
            root.subPageIdxStack.length = 0;
    }
}
