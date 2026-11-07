import QtQuick
import Quickshell.Windows

QtObject {
    id: test
    readonly property NativeNetworkBackend facade: NativeNetworkBackend {}
    property int assertions: 0
    property var results: []
    property bool reenter: false
    readonly property Connections resultWatch: Connections {
        target: test.facade
        function onConnectResultById(id, ssid, success, reason): void {
            test.results = [...test.results, { id, ssid, success, reason }];
            if (test.reenter) {
                test.reenter = false;
                test.facade.connectToNetworkById("next-id", "Same name", "");
            }
        }
        function onConnectResult(ssid, success, reason): void {
            test.results = [...test.results, { id: "", ssid, success, reason }];
        }
    }
    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }
    function run(): void {
        check(facade.selectionIdentityAvailable, "new native ID methods detected");
        check(Network.idConnects === 0 && Network.legacyConnects === 0
            && Network.idForgets === 0 && Network.legacyForgets === 0, "construction has no write");
        facade.connectToNetworkById("profile-a", "Same name", "");
        check(Network.idConnects === 1 && Network.legacyConnects === 0, "ID dispatch never uses a display name");
        check(Network.lastId === "profile-a" && Network.lastPassword === "", "exact ID and no credential");
        Network.wifiConnectResult("profile-a", false, "stale-or-ambiguous");
        check(results.length === 1 && results[0].id === "profile-a"
            && results[0].ssid === "Same name" && !results[0].success, "stale-ID native refusal retains row identity");
        check(facade.pendingSelectionId === "", "synchronous terminal releases mapping");
        facade.connectToNetworkById("profile-b", "Same name", "");
        Network.wifiConnectResult("another name", true, "");
        check(results.length === 1 && facade.pendingSelectionId === "profile-b", "foreign observation ignored");
        reenter = true;
        Network.wifiConnectResult("Same name", true, "");
        check(results.length === 2 && results[1].id === "profile-b" && results[1].success, "correct completion stays ID-bound");
        check(facade.pendingSelectionId === "next-id" && Network.lastId === "next-id",
            "completion clears old mapping before a reentrant request");
        Network.wifiConnectResult("Same name", false, "completion-unobserved");
        check(results.length === 3 && results[2].id === "next-id"
            && !results[2].success && facade.pendingSelectionId === "", "timeout is terminal non-success");
        facade.forgetNetworkById("profile-b");
        check(Network.idForgets === 1 && Network.lastId === "profile-b" && Network.legacyForgets === 0,
            "forget uses exact identity");
        facade.connectToNetwork("Legacy single name", "");
        Network.wifiConnectResult("Legacy single name", true, "");
        check(results.length === 4 && results[3].id === "" && results[3].ssid === "Legacy single name",
            "legacy compatibility result preserved");
        console.log("CAELESTIA_NETWORK_IDENTITY_PASS " + JSON.stringify({ assertions }));
        Qt.quit();
    }
    Component.onCompleted: Qt.callLater(() => {
        try { test.run(); }
        catch (error) { console.error("CAELESTIA_NETWORK_IDENTITY_FAIL " + error.message); Qt.exit(1); }
    })
}
