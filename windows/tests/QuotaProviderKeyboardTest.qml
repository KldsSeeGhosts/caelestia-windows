import QtQuick
import QtQuick.Controls
import QtTest

Item {
    id: root
    width: 400
    height: 100

    function providerIconSource(provider) { return ""; }
    QtObject {
        id: logic
        function groupWorstRemain(group) { return null; }
    }
    QtObject {
        id: quota
        property var providerGroups: [
            { provider: "codex", label: "Codex" },
            { provider: "claude", label: "Claude" }
        ]
        property var activeGroup: providerGroups[0]
        property int selections: 0
        function selectGroup(provider) {
            activeGroup = providerGroups.find(group => group.provider === provider);
            selections++;
        }
    }
    Row {
        id: strip
        property real segment: 100
        height: 54
        Repeater {
            id: tabs
            model: quota.providerGroups
            // PROVIDER_DELEGATE
        }
    }
    TestCase {
        name: "QuotaProviderKeyboard"
        when: windowShown

        function init() {
            quota.activeGroup = quota.providerGroups[0];
            quota.selections = 0;
            tabs.itemAt(1).enabled = true;
            tabs.itemAt(0).forceActiveFocus(Qt.TabFocusReason);
            tryVerify(() => tabs.itemAt(0).activeFocus);
        }
        function test_select_data() {
            return [
                { tag: "Return", key: Qt.Key_Return },
                { tag: "keypad Enter", key: Qt.Key_Enter },
                { tag: "Space", key: Qt.Key_Space }
            ];
        }
        function test_select(data) {
            keyClick(Qt.Key_Tab);
            verify(tabs.itemAt(1).activeFocus, "Tab focuses Claude");
            compare(quota.activeGroup.provider, "codex", "focus alone does not select");
            keyClick(data.key);
            compare(quota.activeGroup.provider, "claude");
            compare(quota.selections, 1, "exactly one activation per key click");
            verify(tabs.itemAt(1).activeFocus, "activation retains focus");
            keyClick(Qt.Key_Tab, Qt.ShiftModifier);
            verify(tabs.itemAt(0).activeFocus, "Shift+Tab moves back");
            compare(quota.activeGroup.provider, "claude", "navigation does not select");
        }
        function test_pointer() {
            mouseClick(tabs.itemAt(1), 50, 20);
            compare(quota.activeGroup.provider, "claude");
            compare(quota.selections, 1);
        }
        function test_disabled() {
            tabs.itemAt(1).enabled = false;
            tabs.itemAt(1).click();
            compare(quota.activeGroup.provider, "codex");
            compare(quota.selections, 0, "click respects disabled controls");
        }
    }
}
