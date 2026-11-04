import QtQuick
import QtTest
import Quickshell
import Caelestia
import Caelestia.Config
import qs.services
import qs.modules.quota as QuotaPanel

// The real quota Content with synthetic spend and reset credits: OpenUsage's
// hover details on a spend row and on "Limit Resets", and the "…" menu.
// Checks the hover timing, the arrow, what each detail shows and that "Use"
// does nothing yet, and saves fixture screenshots to the profile's state
// folder for the PR. No reset endpoint exists here, and none is called.
ShellRoot {
    id: root
    property int assertions: 0
    property var input: null
    property Component inputComponent: Component { TestCase { when: false } }
    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 400
        implicitHeight: 760
        color: Colours.palette.m3surface
        contentItem.Config.screen: Quickshell.screens[0]?.name ?? ""
        QuotaPanel.Content {
            id: content
            x: 12
            y: 12
            width: 376
            height: 736
        }
    }
    function check(value, message): void {
        assertions++;
        if (!value) throw new Error(message);
    }
    function item(name): var {
        return CUtils.findChildren(content, name)[0];
    }
    function inDetail(name): var {
        const detail = item("quotaPopover").detailItem;
        return detail ? CUtils.findChildren(detail, name)[0] : null;
    }
    function rowNamed(label): var {
        return CUtils.findChildren(content, "quotaValueRow").find(r => r.visible && r.label === label);
    }
    function centreX(target): real {
        return target.mapToItem(content, target.width - target.contentWidth / 2, 0).x;
    }
    // Saves the window into the fixture's disposable profile (the runner sets
    // CAELESTIA_STATE_DIR there; never the real Quickshell state folder), then
    // carries on. Without it, nothing is saved.
    readonly property string captureDir: (Quickshell.env("CAELESTIA_STATE_DIR") ?? "").replace(/\\/g, "/")
    function capture(name, then): void {
        if (!captureDir) {
            then();
            return;
        }
        CUtils.saveItem(win.contentItem, Qt.resolvedUrl("file:///" + captureDir + "/quota-" + name + ".png"), () => {
            console.log("CAELESTIA_QUOTA_POPOVER_CAPTURE " + name);
            then();
        }, () => fail("capture " + name));
    }
    function fail(error): void {
        console.error("CAELESTIA_QUOTA_POPOVER_FAIL " + error);
        Qt.exit(1);
    }
    function step(fn): void {
        try {
            fn();
        } catch (error) {
            fail(error + (error.lineNumber ? " (line " + error.lineNumber + ")" : ""));
        }
    }
    // The shell's fonts, so the screenshots show text (offscreen has none).
    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }
    readonly property bool fontsReady: bodyFont.status !== FontLoader.Loading && iconFont.status !== FontLoader.Loading
    property bool started: false
    onFontsReadyChanged: start()
    Component.onCompleted: start()
    function start(): void {
        if (!fontsReady || started)
            return;
        started = true;
        Qt.callLater(() => step(run));
    }

    function run(): void {
        input = inputComponent.createObject(win.contentItem);
        const popover = item("quotaPopover");
        check(!!popover && !popover.open, "the popover starts closed");

        // (a) A spend row: hover reveals the breakdown after OpenUsage's 400 ms.
        // Claude's section is second, so scroll it into view first.
        const yesterday = CUtils.findChildren(content, "quotaValueRow").filter(r => r.label === "Yesterday")[1];
        check(!!yesterday && yesterday.hasDetail, "Claude's Yesterday row has a detail");
        const body = item("quotaBody");
        body.contentY = Math.max(0, yesterday.mapToItem(body.contentItem, 0, 0).y - body.height + 160);
        yesterday.detailHover(yesterday.figure, true);
        input.wait(200);
        check(!popover.open, "not before the reveal delay");
        input.wait(300);
        check(popover.open && popover.anchorItem === yesterday.figure, "hover opens the breakdown");
        check(yesterday.lit, "the figure keeps its hover chip while its detail is open");
        const breakdown = popover.detailItem;
        check(breakdown.width === 288, "the breakdown is 288 dp");
        check(inDetail("quotaBreakdownTitle").text === "Yesterday", "caption names the range");
        check(inDetail("quotaBreakdownHeadline").text === "$6.20", "headline is Claude's own cost: " + inDetail("quotaBreakdownHeadline").text);
        check(!inDetail("quotaTokenMix").visible && !inDetail("quotaTopModels").visible, "no token mix or models are invented from a cost");
        const arrow = popover.arrowItem;
        const tip = popover.x + arrow.x + arrow.width / 2;
        check(Math.abs(tip - centreX(yesterday.figure)) <= 1, "the arrow points at the figure: " + tip + " vs " + centreX(yesterday.figure));
        yesterday.detailHover(yesterday.figure, false);
        input.wait(250);
        check(!popover.open, "leaving closes it after the hide grace");

        // The full structure, from synthetic fixture data only.
        yesterday.detailClicked(yesterday.figure);
        check(popover.open && popover.explicit, "a click opens it explicitly");
        popover.detailData = {
            title: "Yesterday",
            figures: ["348.7M tokens"],
            tokenParts: [
                { title: "Cache Read", number: 331.4e6 },
                { title: "Input", number: 16.1e6 },
                { title: "Output", number: 1.2e6 }
            ],
            fillsTotal: true,
            models: [
                { name: "fixture-model-a", value: "55%" },
                { name: "fixture-model-b", value: "33%" },
                { name: "fixture-model-c", value: "13%" }
            ]
        };
        check(inDetail("quotaTokenMix").visible && inDetail("quotaTopModels").visible, "token mix and Top Models show when the data has them");
        check(CUtils.findChildren(item("quotaPopover").detailItem, "quotaTokenPart").length === 3, "one bar segment per token kind");
        input.wait(50);
        capture("breakdown", () => step(resets));
    }

    function resets(): void {
        const popover = item("quotaPopover");
        popover.dismiss();
        // (b) Limit Resets: the row shows only where the data has credits.
        const rows = CUtils.findChildren(content, "quotaLimitResets");
        check(rows.filter(r => r.visible).length === 1, "Limit Resets shows only on the account with credits");
        const row = rows.find(r => r.visible);
        check(row.value === "3 available" && row.severity === "warning", "3 available, warning: the next expires within 7 days");
        const body = item("quotaBody");
        body.contentY = Math.max(0, row.mapToItem(body.contentItem, 0, 0).y - 40);
        row.detailClicked(row.figure);
        const detail = popover.detailItem;
        check(popover.open && detail.width === 250, "the resets detail is 250 dp");
        const entries = CUtils.findChildren(detail, "quotaResetEntry");
        check(entries.length === 3 && entries.every(e => e.height === 30), "three 30 dp entries");
        check(entries.map(e => e.modelData.number).join(",") === "1,2,3", "numbered earliest first");
        check(entries[0].modelData.severity === "warning" && entries[1].modelData.severity === "normal", "expiry colours");
        check(/^[A-Z][a-z]{2} \d+ at \d+:\d\d [AP]M$/.test(entries[1].modelData.time), "an OpenUsage date: " + entries[1].modelData.time);
        check(/^2[56]d \d+h$/.test(entries[1].modelData.countdown), "a countdown: " + entries[1].modelData.countdown);
        // Hovering the first row swaps its countdown for "Use".
        detail.hovered = 0;
        const uses = CUtils.findChildren(detail, "quotaResetUse");
        check(uses[0].visible && !uses[1].visible && !uses[2].visible, "Use shows on the hovered row only");
        const before = [Quota.refreshes, Quota.keepalives];
        uses[0].click();
        check(Quota.refreshes === before[0] && Quota.keepalives === before[1] && popover.open, "Use is a stub: nothing happens");
        input.wait(50);
        capture("resets", () => step(menu));
    }

    function menu(): void {
        item("quotaPopover").dismiss();
        item("quotaBody").contentY = Math.max(0, item("quotaBody").contentHeight - item("quotaBody").height);
        item("quotaMore").click();
        check(item("quotaMenu").visible, "the menu opens");
        input.wait(50);
        capture("menu", () => {
            item("quotaMenu").hide();
            console.log("CAELESTIA_QUOTA_POPOVER_PASS " + assertions);
            Qt.quit();
        });
    }
}
