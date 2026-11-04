import QtQuick
import QtTest
import Quickshell
import Caelestia
import Caelestia.Config
import qs.services
import qs.modules.quota as QuotaPanel

// Drive the entire real quota Content, not a cropped delegate: the Priority |
// All Usage segments, the scrolling body and the footer's "..." menu, by
// keyboard and by pointer.
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
            height: 500
        }
    }
    function check(value, message): void {
        assertions++;
        if (!value) throw new Error(message);
    }
    function item(name): var {
        return CUtils.findChildren(content, name)[0];
    }
    function menuItem(key): var {
        return CUtils.findChildren(content, "quotaMenuItem").find(i => i.modelData.key === key);
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            input = inputComponent.createObject(win.contentItem);
            const segments = CUtils.findChildren(content, "quotaSegment");
            check(segments.length === 2, "real content exposes two segments");
            check(CUtils.findChildren(content, "quotaProviderTab").length === 0, "the provider strip is gone");
            check(Quota.usageView === "all", "All Usage is the default");
            check(CUtils.findChildren(content, "quotaSection").length === 3, "All Usage lists every provider");

            // Segments: Tab reaches them, focus alone does not switch, each key does.
            for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space]) {
                Quota.usageView = "all";
                Quota.viewChanges = 0;
                segments[0].forceActiveFocus(Qt.TabFocusReason);
                check(segments[0].activeFocus, "first segment takes focus");
                check(Quota.usageView === "all", "focus alone does not switch");
                input.keyClick(key);
                check(Quota.usageView === "priority", "key switches to Priority");
                check(Quota.viewChanges === 1, "one switch per key");
                check(segments[0].activeFocus, "activation retains focus");
                input.keyClick(Qt.Key_Tab);
                check(segments[1].activeFocus, "Tab reaches All Usage");
                input.keyClick(key);
                check(Quota.usageView === "all" && Quota.viewChanges === 2, "key switches back to All Usage");
                input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
                check(segments[0].activeFocus, "Shift+Tab returns to Priority");
            }
            Quota.usageView = "all";
            input.mouseClick(segments[0], segments[0].width / 2, segments[0].height / 2);
            check(Quota.usageView === "priority", "pointer switches to Priority");
            check(CUtils.findChildren(content, "quotaSection").length === 0, "Priority hides the provider sections");
            check(CUtils.findChildren(content, "quotaPriorityRow").length === 5, "Priority lists each account once");
            Quota.usageView = "all";

            // Tab order: segments, then the scrolling content, then the more button.
            const body = item("quotaBody");
            const more = item("quotaMore");
            segments[1].forceActiveFocus(Qt.TabFocusReason);
            input.keyClick(Qt.Key_Tab);
            check(body.activeFocus, "Tab reaches the scrolling content");
            input.keyClick(Qt.Key_Tab);
            check(more.activeFocus, "Tab reaches the more button");
            input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
            check(body.activeFocus, "Shift+Tab returns to the content");
            check(body.contentHeight > body.height, "the fixture drawer scrolls");
            body.contentY = 0;
            input.keyClick(Qt.Key_Down);
            check(body.contentY > 0, "Down scrolls");
            const stepped = body.contentY;
            input.keyClick(Qt.Key_Up);
            check(body.contentY < stepped, "Up scrolls back");
            input.keyClick(Qt.Key_PageDown);
            check(body.contentY > stepped, "Page Down scrolls");
            input.keyClick(Qt.Key_End);
            check(Math.abs(body.contentY - (body.contentHeight - body.height)) < 1, "End reaches the bottom");
            input.keyClick(Qt.Key_Home);
            check(body.contentY === 0, "Home returns to the top");

            // The "..." menu: open, move, act, close, by key and by pointer.
            const menu = item("quotaMenu");
            check(!menu.visible, "the menu starts closed");
            for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space]) {
                more.forceActiveFocus(Qt.TabFocusReason);
                input.keyClick(key);
                check(menu.visible, "key opens the menu");
                check(menuItem("refresh").activeFocus, "the menu opens on Refresh now");
                input.keyClick(Qt.Key_Down);
                check(menuItem("keepalive").activeFocus, "Down moves to Keepalive");
                input.keyClick(Qt.Key_Down);
                check(menuItem("keepalive").activeFocus, "Down stops at the last entry");
                input.keyClick(Qt.Key_Up);
                check(menuItem("refresh").activeFocus, "Up moves back");
                input.keyClick(Qt.Key_Escape);
                check(!menu.visible, "Escape closes the menu");
                check(more.activeFocus, "Escape returns focus to the button");
            }
            Quota.refreshes = 0;
            Quota.keepalives = 0;
            more.forceActiveFocus(Qt.TabFocusReason);
            input.keyClick(Qt.Key_Return);
            input.keyClick(Qt.Key_Return);
            check(Quota.refreshes === 1 && Quota.keepalives === 0, "Return on Refresh now refreshes once");
            check(!menu.visible && more.activeFocus, "acting closes the menu and returns focus");
            input.keyClick(Qt.Key_Return);
            input.keyClick(Qt.Key_Down);
            input.keyClick(Qt.Key_Enter);
            check(Quota.keepalives === 1 && Quota.refreshes === 1, "Enter on Keepalive runs it once");
            input.keyClick(Qt.Key_Return);
            input.keyClick(Qt.Key_Tab);
            check(!menu.visible, "tabbing away closes the menu");
            input.mouseClick(more, more.width / 2, more.height / 2);
            check(menu.visible, "pointer opens the menu");
            input.mouseClick(menuItem("refresh"), 20, 10);
            check(Quota.refreshes === 2 && !menu.visible, "pointer on Refresh now refreshes and closes");
            Quota.refreshes = 0;
            Quota.keepaliveRunning = true;
            more.forceActiveFocus(Qt.TabFocusReason);
            input.keyClick(Qt.Key_Return);
            check(!menuItem("keepalive").enabled, "Keepalive is off while it runs");
            menuItem("keepalive").click();
            check(Quota.keepalives === 1, "a disabled entry does not activate");
            input.keyClick(Qt.Key_Escape);
            console.log("CAELESTIA_QUOTA_PROVIDER_KEYBOARD_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_QUOTA_PROVIDER_KEYBOARD_FAIL " + error);
            Qt.exit(1);
        }
    }
}
