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
    property int accountsRequests: 0
    property int settingsRequests: 0
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
            onAccountsRequested: root.accountsRequests++
            onSettingsRequested: root.settingsRequests++
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
    function near(a, b): bool {
        return Math.abs(a - b) < 0.5;
    }
    // The OpenUsage metrics that matter most (DashboardGrid.swift,
    // CapsuleSegments.swift, PopoverFooter.swift), measured on the real Content.
    function checkMetrics(): void {
        const segments = item("quotaSegments");
        check(segments.height === 28, "segmented control is 28 dp: " + segments.height);
        check(item("quotaSegmentPill").height === 24, "the thumb sits 2 dp inside the track");
        const meters = CUtils.findChildren(content, "quotaMeter");
        check(meters.length > 0 && meters.every(m => m.height === 22), "meter rows are 22 dp");
        const bar = CUtils.findChildren(meters[0], "quotaBar")[0];
        check(bar.height === 9, "the bar slot is 9 dp: " + bar.height);
        check(CUtils.findChildren(bar, "quotaBarFill")[0].height === 8, "the bar is 8 dp");
        const grid = content.grid;
        check(grid.label === 90 && grid.value === 52 && grid.reset === 48 && grid.gap === 8, "OpenUsage's column grid");
        check(near(bar.width, grid.bar), "the bar takes the rest of the row: " + bar.width + " vs " + grid.bar);
        // Remaining mode: account "one" has used 40% of its 5-hour window, so
        // the row reads 60% and the bar is 60% full.
        check(CUtils.findChildren(meters[0], "quotaMeterLeft")[0].text === "60%", "All Usage shows the % left");
        check(Math.abs(CUtils.findChildren(bar, "quotaBarFill")[0].width - Math.round(bar.width * 0.6)) <= 1, "the bar fills with the share left");
        const sections = CUtils.findChildren(content, "quotaSection");
        const card = CUtils.findChildren(sections[0], "quotaCard")[0];
        const name = CUtils.findChildren(card, "quotaAccountName")[0];
        const first = CUtils.findChildren(card, "quotaMeter")[0];
        check(near(name.mapToItem(card, 0, 0).x, 12), "card padding is 12 at the side");
        check(near(name.parent.mapToItem(card, 0, 0).y, 8), "card padding is 8 at the top");
        check(near(name.parent.height, 14) && near(first.mapToItem(card, 0, 0).y, 8 + 14 + 4), "caption 14 dp, 4 dp above the rows");
        const lastMeter = CUtils.findChildren(card, "quotaMeter").slice(-1)[0];
        check(near(card.height - (lastMeter.mapToItem(card, 0, 0).y + lastMeter.height), 10), "card padding is 10 at the bottom");
        check(near(card.mapToItem(sections[0], 0, 0).y, 24 + 4), "24 dp header, 4 dp to the card");
        check(near(sections[1].mapToItem(content, 0, 0).y - (sections[0].mapToItem(content, 0, 0).y + sections[0].height), 14), "sections are 14 dp apart");
        check(near(card.radius, 12), "cards have a 12 dp radius");
        const more = item("quotaMore");
        check(more.width === 26 && more.height === 26, "the footer button is 26 dp");
        check(item("quotaFooter").height === 34, "footer: divider, 7 dp, 26 dp controls (the margin is the drawer's)");
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
            checkMetrics();

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
            // OpenUsage's rule: every window at 30% left or less, least left first.
            const rows = CUtils.findChildren(content, "quotaPriorityRow");
            check(rows.length === 3, "Priority lists the three windows at 30% left or less: " + rows.length);
            check(rows.map(r => Math.round(r.remaining * 100)).join(",") === "10,30,30", "least left first");
            check(rows[1].accountLabel === "two" && rows[2].accountLabel === "three", "ties keep the drawer order");
            check(rows.every(r => r.height === 46), "Priority rows are 46 dp");
            check(CUtils.findChildren(rows[0], "quotaMeterLeft")[0].text === "10% left", "Priority reads OpenUsage's remaining mode: 10% left");
            check(CUtils.findChildren(content, "quotaGauge").every(g => g.width === 32 && g.height === 32), "the gauge ring is 32 dp");
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
                check(menuItem("accounts").activeFocus, "Down steps over the separator to Accounts");
                input.keyClick(Qt.Key_Down);
                check(menuItem("settings").activeFocus, "Down moves to Settings");
                input.keyClick(Qt.Key_Down);
                check(menuItem("settings").activeFocus, "Down stops at the last entry");
                input.keyClick(Qt.Key_Up);
                input.keyClick(Qt.Key_Up);
                check(menuItem("keepalive").activeFocus, "Up steps back over the separator");
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
            Quota.keepaliveRunning = false;

            // OpenUsage's menu: our two actions, a separator, then Accounts and
            // Settings with their shortcut hints; app-level items are left out.
            const labels = CUtils.findChildren(content, "quotaMenuItem").map(i => i.modelData.label);
            check(labels.join("|") === "Refresh now|Keepalive|Accounts|Settings", "menu items: " + labels.join("|"));
            check(CUtils.findChildren(content, "quotaMenuSeparator").length === 1, "one separator");
            check(CUtils.findChildren(content, "quotaMenuItem").every(i => i.height === 24), "menu items are 24 dp");
            const hints = CUtils.findChildren(content, "quotaMenuShortcut").map(s => s.text).filter(s => s !== "");
            check(hints.join("|") === "Ctrl+R|Ctrl+,", "shortcut hints: " + hints.join("|"));
            check(menuItem("accounts") && CUtils.findChildren(menuItem("accounts"), "quotaMenuShortcutIcon")[0].text === "keyboard_return", "Accounts shows the Return key");
            more.forceActiveFocus(Qt.TabFocusReason);
            input.keyClick(Qt.Key_Return);
            input.keyClick(Qt.Key_Down);
            input.keyClick(Qt.Key_Down);
            input.keyClick(Qt.Key_Return);
            check(accountsRequests === 1 && !menu.visible, "Accounts asks for Nexus and closes the menu");
            input.keyClick(Qt.Key_Return);
            for (let i = 0; i < 3; i++)
                input.keyClick(Qt.Key_Down);
            input.keyClick(Qt.Key_Return);
            check(settingsRequests === 1 && accountsRequests === 1, "Settings asks for Nexus");
            // The popover keys: Return on the content opens Accounts, Ctrl+,
            // Settings and Ctrl+R refreshes.
            body.forceActiveFocus(Qt.TabFocusReason);
            input.keyClick(Qt.Key_Return);
            check(accountsRequests === 2, "Return opens Accounts");
            input.keyClick(Qt.Key_Comma, Qt.ControlModifier);
            check(settingsRequests === 2, "Ctrl+, opens Settings");
            Quota.refreshes = 0;
            input.keyClick(Qt.Key_R, Qt.ControlModifier);
            check(Quota.refreshes === 1, "Ctrl+R refreshes");
            console.log("CAELESTIA_QUOTA_PROVIDER_KEYBOARD_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_QUOTA_PROVIDER_KEYBOARD_FAIL " + error);
            Qt.exit(1);
        }
    }
}
