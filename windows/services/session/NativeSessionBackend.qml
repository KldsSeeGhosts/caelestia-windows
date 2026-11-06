import QtQuick
import Quickshell.Windows

// Thin facade over the pinned Quickshell.Windows.Session singleton. It is
// loaded by URL only after the observation opt-in, so the default-off host
// resolves no native Session singleton.
//
// Every action method is a void native call. The pinned backend logs failures
// and exposes no result (windows/deps/quickshell/src/windows/system/session.cpp
// lines 45-115). canHibernate is the singleton's CONSTANT property backed by
// GetPwrCapabilities().HiberFilePresent (lines 117-121).
QtObject {
    id: root

    readonly property bool canHibernate: Session.canHibernate

    function lock(): void {
        Session.lock();
    }

    function logout(): void {
        Session.logout();
    }

    function shutdown(): void {
        Session.shutdown();
    }

    function reboot(): void {
        Session.reboot();
    }

    function suspend(): void {
        Session.suspend();
    }

    function hibernate(): void {
        Session.hibernate();
    }

    function rebootToFirmware(): void {
        Session.rebootToFirmware();
    }
}
