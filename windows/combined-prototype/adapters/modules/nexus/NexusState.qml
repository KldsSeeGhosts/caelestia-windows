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
// never imports. Every other field, signal and sub-page helper is the upstream
// one.
QtObject {
    property ShellScreen screen
    property bool isWindow
    property bool animatingContainer
    property int currentPageIdx
    property list<int> subPageIdxStack
    property bool searchOpen

    property string selectedWallpaperCategory
    property var selectedBtDevice
    property var selectedApp
    property int editingVpnIndex: -1
    property string selectedNetworkSsid
    property string selectedEthernetInterface
    property bool networkDetailsFromSaved

    signal close
    signal subPageOpened(idx: int)
    signal subPageClosed

    function openSubPage(idx: int): void {
        subPageIdxStack.push(idx);
        subPageOpened(idx);
    }

    function closeSubPage(): void {
        subPageClosed();
        subPageIdxStack.pop();
    }

    onCurrentPageIdxChanged: subPageIdxStack.length = 0
}
