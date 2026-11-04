import QtQuick
import QtTest
import Quickshell
import Caelestia
import Caelestia.Config
import qs.services
import qs.modules.quota as QuotaPanel

// Drive the entire real quota Content, not a cropped provider delegate.
ShellRoot {
    id: root
    property int assertions: 0
    property var input: null
    property Component inputComponent: Component { TestCase { when: false } }
    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 420
        implicitHeight: 720
        contentItem.Config.screen: Quickshell.screens[0]?.name ?? ""
        QuotaPanel.Content {
            id: content
            width: 400
            height: 700
        }
    }
    function check(value, message): void {
        assertions++;
        if (!value) throw new Error(message);
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            input = inputComponent.createObject(win.contentItem);
            const tabs = CUtils.findChildren(content, "quotaProviderTab");
            check(tabs.length === 2, "real content exposes two provider buttons");
            for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space]) {
                Quota.activeGroup = Quota.providerGroups[0];
                Quota.selections = 0;
                tabs[0].forceActiveFocus(Qt.TabFocusReason);
                check(tabs[0].activeFocus, "first tab takes focus");
                input.keyClick(Qt.Key_Tab);
                check(tabs[1].activeFocus, "Tab focuses second provider");
                check(Quota.activeGroup.provider === "codex", "focus alone does not select");
                input.keyClick(key);
                check(Quota.activeGroup.provider === "claude", "activation selects provider");
                check(Quota.selections === 1, "one activation per key");
                check(tabs[1].activeFocus, "activation retains focus");
                input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
                check(tabs[0].activeFocus, "Shift+Tab returns to first provider");
                check(Quota.activeGroup.provider === "claude", "navigation preserves selection");
            }
            Quota.activeGroup = Quota.providerGroups[0];
            Quota.selections = 0;
            input.mouseClick(tabs[1], tabs[1].width / 2, tabs[1].height / 2);
            check(Quota.activeGroup.provider === "claude", "pointer selects provider");
            check(Quota.selections === 1, "one pointer activation");
            Quota.activeGroup = Quota.providerGroups[0];
            Quota.selections = 0;
            tabs[1].enabled = false;
            tabs[1].click();
            check(Quota.activeGroup.provider === "codex" && Quota.selections === 0, "disabled provider does not activate");
            console.log("CAELESTIA_QUOTA_PROVIDER_KEYBOARD_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_QUOTA_PROVIDER_KEYBOARD_FAIL " + error);
            Qt.exit(1);
        }
    }
}
