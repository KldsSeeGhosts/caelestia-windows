import QtQuick
import qs.services

// Windows combined host wiring for the original network popout, matching the
// bounded network prototype host. The read-only facade refuses every radio,
// connect, disconnect and forget request and never requests a scan, so the
// original list stays a read-only observation and the password dialog is
// unreachable.
NetworkContent {
    view: Nmcli.activeEthernet ? "ethernet" : "wireless"
    controlsEnabled: Nmcli.controlsEnabled
    nativeConnect: true
    onConnectRequested: accessPoint => Nmcli.connectToAccessPoint(accessPoint)
    nativeConnectingSsid: Nmcli.connectingSsid
    ethernetControlAvailable: Nmcli.ethernetControlSupported
    statusText: Nmcli.resultText.length > 0
        ? Nmcli.resultText : (Nmcli.listHidden ? Nmcli.reason : "")
}
