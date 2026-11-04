// Windows CPA quota smoke host.
//
// Staged into the production graph by windows/scripts/Test-Quota.ps1 and run
// with an isolated profile and the offscreen platform. The offscreen QPA has no
// PanelWindow backend, so it instantiates the original drawer Panels (which
// creates Quota.Wrapper) instead of ContentWindow. That still exercises the real
// staging, singleton service, panel layout, meters and provider marks.
//
//   * configured: a local synthetic CPA Manager stub serves the pre-aggregated
//     quota summary; the drawer opens on All Usage with one section per
//     provider on a shared column grid, then switches to Priority (sorted, least
//     left first), opens the footer menu, and saves dark and light screenshots;
//   * states: a second scenario of long names, 0% left, stale, reconnect,
//     disabled and unreported accounts, checked section by section;
//   * offline: the endpoint refuses connections and, when the configured run
//     left a cached summary, the drawer keeps that reading with the one friendly
//     saved-data line; it must never hang;
//   * unconfigured: no cpa-agents.json exists; the service makes no request and
//     the drawer stays disabled;
//   * disabled: the "Agent usage panel" setting (windows.quota.enabled) is off
//     with a valid CPA config. The drawer never opens, its input region is
//     empty and the service makes no request. Switching it on and off again at
//     runtime opens, closes and quiets the drawer live, and the cache survives.
//
// No external network, credentials, pointer input or live desktop is used.
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.State
import qs.components
import qs.services
import qs.modules.bar as Bar
import qs.modules.bar.popouts as BarPopouts
import qs.modules.drawers

ShellRoot {
    id: root

    settings.watchFiles: false

    readonly property string mode: Quickshell.env("CAELESTIA_QUOTA_SMOKE_MODE") || "configured"
    readonly property bool saved: Quickshell.env("CAELESTIA_QUOTA_SMOKE_SAVED") === "1"
    readonly property ShellScreen selectedScreen: Quickshell.screens[0] ?? null
    readonly property ScreenState screenState: ShellState.forScreen(root.selectedScreen)
    readonly property int inset: 60
    readonly property int previewWidth: Math.min(900, (selectedScreen?.width ?? 1060) - inset * 2)
    // The offscreen screen is small, but the 520 dp default drawer has to fit in the frame.
    readonly property int previewHeight: 660
    // Configured drawer size, "<width>x<height>", as written to quota.json by Test-Quota.ps1.
    readonly property var geometry: {
        const match = /^(\d+)x(\d+)$/.exec(Quickshell.env("CAELESTIA_QUOTA_SMOKE_GEOMETRY") || "");
        return match ? { w: Number(match[1]), h: Number(match[2]) } : { w: 384, h: 520 };
    }
    readonly property string priorityScreenshotPath: Quickshell.env("CAELESTIA_QUOTA_PRIORITY_SCREENSHOT")
    readonly property string menuScreenshotPath: Quickshell.env("CAELESTIA_QUOTA_MENU_SCREENSHOT")
    readonly property string screenshotPath: Quickshell.env("CAELESTIA_SHELL_SCREENSHOT")
    readonly property string lightScreenshotPath: Quickshell.env("CAELESTIA_QUOTA_LIGHT_SCREENSHOT")
    readonly property string lightSchemePath: Quickshell.env("CAELESTIA_QUOTA_LIGHT_SCHEME")

    // Same process-local fonts as the production entry, so text shaping is the
    // real one rather than a system fallback.
    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }
    FontLoader {
        id: clockFont
        source: Quickshell.shellPath("assets/rubik/Rubik.ttf")
    }

    // Optional light palette for a second configured screenshot. The fixture is
    // a fixed Material 3 light scheme, not a generated wallpaper palette.
    FileView {
        id: lightScheme

        path: root.lightSchemePath
        printErrors: false
    }

    // The mask builder only reads geometry and config from the window, so a
    // plain object stands in for ContentWindow and keeps the input-region
    // wiring compiled offscreen.
    QtObject {
        id: fakeWin

        property real width: host.width
        property real height: host.height
        property real dragMaskPadding: 0
        property Item contentItem: Item {}
    }

    readonly property Region quotaRegions: Regions {
        bar: bar
        panels: panelsRoot
        win: fakeWin
    }
    // The quota drawer's own input region is the first child, as in Regions.qml.
    function quotaRegion(): var {
        return quotaRegions.regions[0];
    }

    // Simulated desktop behind the shell surface. The real ContentWindow paints
    // the same blob, but cannot be constructed without a native panel backend.
    // A plain offscreen QQuickWindow gives saveItem a window to render into.
    Window {
        id: preview

        visible: true
        width: root.previewWidth + root.inset * 2
        height: root.previewHeight + root.inset * 2
        color: "transparent"

        Rectangle {
            id: host

            x: root.inset
            y: root.inset
            width: root.previewWidth
            height: root.previewHeight
            color: Colours.palette.m3surfaceContainerLow

            // Smoke-only surface. The real ContentWindow supplies the original
            // blob background; a plain card keeps the offscreen screenshot legible
            // without a native panel window or the layered blob group.
            Rectangle {
                id: quotaSurface

                visible: panelsRoot.quota.visible
                x: panelsRoot.x + panelsRoot.quota.x
                y: panelsRoot.y + panelsRoot.quota.y
                width: panelsRoot.quota.width
                height: panelsRoot.quota.height
                radius: Tokens.rounding.extraLarge
                color: Colours.tPalette.m3surface
                border.width: 1
                border.color: Colours.palette.m3outlineVariant
            }

            BarPopouts.ClipWrapper {
                id: popouts

                screen: root.selectedScreen
                borderThickness: 1
            }

            Bar.BarWrapper {
                id: bar

                screen: root.selectedScreen
                screenState: root.screenState
                popouts: popouts.content
                fullscreen: false
            }

            Panels {
                id: panelsRoot

                anchors.fill: parent
                anchors.margins: 1

                screen: root.selectedScreen
                screenState: root.screenState
                bar: bar
                borderThickness: 1
            }

            // Instantiate the shared hover handler so its quota strip and
            // close-path references are compiled and resolved. Input stays off.
            Interactions {
                anchors.fill: parent
                enabled: false
                screen: root.selectedScreen
                popouts: popouts.content
                screenState: root.screenState
                panels: panelsRoot
                bar: bar
                borderThickness: 1
                fullscreen: false
            }
        }
    }

    // Core config-load toasts are unrelated to the quota card; hide the shared
    // toast surface so the evidence frame only shows this module.
    Component.onCompleted: if (panelsRoot.toasts)
        panelsRoot.toasts.visible = false;

    function fail(message: string): void {
        console.error("CAELESTIA_QUOTA_SMOKE_FAIL " + message);
        Qt.exit(1);
    }

    // The Content root exposes the drawer reveal state.
    function findContent(item): var {
        for (const child of item.children) {
            if (!child)
                continue;
            if (child.objectName === "quotaContent")
                return child;
            const found = root.findContent(child);
            if (found)
                return found;
        }
        return null;
    }

    function findNamed(item, name): var {
        if (item.objectName === name) return item;
        for (const child of item.children) {
            const found = root.findNamed(child, name);
            if (found) return found;
        }
        return null;
    }

    function collectNamed(item, name, out): void {
        for (const child of item.children) {
            if (!child)
                continue;
            if (child.objectName === name)
                out.push(child);
            root.collectNamed(child, name, out);
        }
    }

    function named(item, name): var {
        const out = [];
        root.collectNamed(item, name, out);
        return out;
    }

    // True when any visible text item under `item` matches `pattern`.
    function hasText(item, pattern): bool {
        for (const child of item.children) {
            if (!child)
                continue;
            if (typeof child.text === "string" && child.visible && pattern.test(child.text))
                return true;
            if (root.hasText(child, pattern))
                return true;
        }
        return false;
    }

    function x0(item, origin): real {
        return item.mapToItem(origin, 0, 0).x;
    }

    function xr(item, origin): real {
        return item.mapToItem(origin, item.width, 0).x;
    }

    // True when every value in `list` is within half a dp of the first.
    function same(list): bool {
        return list.every(v => Math.abs(v - list[0]) < 0.5);
    }

    // Layout facts for the open drawer, in the scroll body's coordinates.
    function measure(quota): var {
        const body = root.findNamed(quota, "quotaBody");
        const content = root.findContent(quota);
        const footer = root.findNamed(quota, "quotaFooter");
        const segments = root.findNamed(quota, "quotaSegments");
        if (!body || !content || !footer || !segments)
            return null;
        const origin = body.contentItem;
        const meters = root.named(origin, "quotaMeter").filter(m => m.visible);
        const bars = meters.map(m => root.findNamed(m, "quotaBar"));
        const pcts = meters.map(m => root.findNamed(m, "quotaMeterLeft"));
        const resets = meters.map(m => root.findNamed(m, "quotaMeterReset"));
        const labels = meters.map(m => root.findNamed(m, "quotaMeterLabel"));
        const priority = root.named(origin, "quotaPriorityRow").filter(r => r.visible);
        const priorityBars = priority.map(r => root.findNamed(r, "quotaBar"));
        const priorityPcts = priority.map(r => root.findNamed(r, "quotaMeterLeft"));
        const values = root.named(origin, "quotaValueRow").filter(r => r.visible && r.label !== "")
            .map(r => root.findNamed(r, "quotaValue"));
        const more = root.findNamed(quota, "quotaMore");
        const status = root.findNamed(quota, "quotaStatus");
        const inside = item => {
            const pos = item.mapToItem(content, 0, 0);
            return item.visible && pos.x >= 0 && pos.x + item.width <= content.width + 1 && pos.y >= 0 && pos.y + item.height <= content.height + 1;
        };
        const everyRow = root.named(origin, "quotaMeter").concat(priority).filter(r => r.visible);
        return {
            body: body, content: content, origin: origin, segments: segments, meters: meters, priority: priority,
            // The columns line up: one x for every bar, % and reset, and the labels start together.
            barX: bars.map(b => root.x0(b, origin)), barW: bars.map(b => b.width),
            pctR: pcts.map(p => root.xr(p, origin)), resetR: resets.map(r => root.xr(r, origin)),
            labelX: labels.map(l => root.x0(l, origin)),
            valueR: values.map(v => root.xr(v, origin)),
            pBarX: priorityBars.map(b => root.x0(b, origin)), pBarW: priorityBars.map(b => b.width),
            pPctR: priorityPcts.map(p => root.xr(p, origin)),
            overflow: everyRow.some(r => root.x0(r, origin) < -1 || root.xr(r, origin) > content.width + 1),
            footerOk: !!more && !!status && inside(more) && inside(status),
            quotaH: quota.height, bodyH: body.height, contentH: body.contentHeight
        };
    }

    // The All Usage view on the shared grid. Returns "" when it holds.
    function allViewError(quota, sections): string {
        const m = root.measure(quota);
        if (!m)
            return "drawer parts missing";
        if (Quota.usageView !== "all" || m.segments.index !== 1)
            return "All Usage is not the default: " + Quota.usageView + " index " + m.segments.index;
        if (root.named(quota, "quotaSegment").length !== 2)
            return "segments: " + root.named(quota, "quotaSegment").length;
        if (root.named(quota, "quotaProviderTab").length !== 0)
            return "the provider strip is still there";
        const titles = root.named(m.origin, "quotaSectionTitle").map(t => t.text);
        if (titles.join("|") !== sections)
            return "sections: " + titles.join("|") + " expected " + sections;
        if (m.meters.length < 4)
            return "fewer than four meters: " + m.meters.length;
        if (!root.same(m.barX) || !root.same(m.barW))
            return "bars do not align: x=" + m.barX.join(",") + " w=" + m.barW.join(",");
        if (!root.same(m.pctR) || !root.same(m.resetR) || !root.same(m.labelX))
            return "columns do not align: pct=" + m.pctR.join(",") + " reset=" + m.resetR.join(",") + " label=" + m.labelX.join(",");
        if (m.valueR.length && !root.same(m.valueR.concat([m.resetR[0]])))
            return "value rows do not end on the reset column: " + m.valueR.join(",") + " vs " + m.resetR[0];
        const content = m.content;
        if (Math.abs(m.barW[0] - content.grid.bar) > 0.5 || content.grid.bar !== Math.round(content.inner * (content.narrow ? 0.30 : 0.40)))
            return "bar column is not " + (content.narrow ? "30" : "40") + "%: " + m.barW[0] + " of " + content.inner;
        if (m.overflow)
            return "content overflows the drawer width";
        if (!m.footerOk)
            return "status or the more button left the footer";
        if (m.quotaH > root.geometry.h + 1)
            return "drawer exceeds its configured height: " + m.quotaH;
        if (m.body.contentY !== 0)
            return "drawer did not open at the top: " + m.body.contentY;
        return "";
    }

    // Priority: least left first, one row per account with a reading.
    function priorityError(quota): string {
        const m = root.measure(quota);
        if (!m)
            return "drawer parts missing";
        // The expectation is computed here, from the summary, not from QuotaLogic.
        const expected = [];
        for (const account of Quota.providers) {
            const used = (account.limits || []).map(l => l.percent).filter(p => p !== null && p !== undefined);
            if (used.length)
                expected.push(1 - Math.max.apply(null, used));
        }
        expected.sort((a, b) => a - b);
        const actual = m.priority.map(r => r.remaining);
        if (actual.length !== expected.length || actual.some((v, i) => Math.abs(v - expected[i]) > 1e-9))
            return "priority order: " + actual.map(v => Math.round(v * 100)).join(",") + " expected " + expected.map(v => Math.round(v * 100)).join(",");
        if (actual.some((v, i) => i > 0 && v < actual[i - 1]))
            return "priority does not ascend: " + actual.join(",");
        if (!root.same(m.pBarX) || !root.same(m.pBarW) || !root.same(m.pPctR))
            return "priority columns do not align: x=" + m.pBarX.join(",") + " w=" + m.pBarW.join(",");
        if (m.overflow)
            return "priority overflows the drawer width";
        if (root.named(m.origin, "quotaSection").length !== 0)
            return "provider sections show under Priority";
        console.log("CAELESTIA_QUOTA_SMOKE_PRIORITY", JSON.stringify({
            rows: actual.length, left: actual.map(v => Math.round(v * 100)).join(","),
            first: m.priority[0].accountLabel
        }));
        return "";
    }

    // The spend rows are one provider's own figures, from the analytics reads.
    function spendError(quota): string {
        const sections = root.named(quota, "quotaSection");
        const claude = sections.find(s => root.findNamed(s, "quotaSectionTitle").text === "Claude");
        if (!claude)
            return "Claude section missing";
        const values = root.named(claude, "quotaValueRow").filter(r => r.visible).map(r => r.label + "=" + r.value).join(" ");
        if (!/Today=\$1\.44/.test(values) || !/Yesterday=\$6\.20/.test(values) || !/Last 30 Days=\$182\.40/.test(values))
            return "Claude spend rows: " + values;
        return "";
    }

    // Honest-state checks for the states fixture, per provider section. Returns ""
    // when the section shows exactly what CPA reported and nothing invented.
    function statesError(quota, index, provider): string {
        const m = root.measure(quota);
        if (!m)
            return "drawer parts missing";
        if (m.overflow)
            return "content overflows the drawer width";
        if (!m.footerOk)
            return "status or the more button left the footer";
        if (m.quotaH > root.geometry.h + 1)
            return "drawer exceeds its configured height: " + m.quotaH;
        const section = root.named(m.origin, "quotaSection")[index];
        if (!section || root.findNamed(section, "quotaSectionTitle").text.toLowerCase().replace(/[^a-z]/g, "") !== provider.replace(/[^a-z]/g, ""))
            return "section " + index + " is not " + provider;
        const meters = root.named(section, "quotaMeter");
        const titles = meters.map(x => x.label).join("|");
        const left = meters.map(x => x.remaining === null ? "null" : String(Math.round(x.remaining * 100)));
        const names = root.named(section, "quotaAccountName");
        const wide = names.find(n => root.xr(n, m.origin) > m.content.width + 1);
        if (wide)
            return "account name overflows the drawer width: x=" + root.x0(wide, m.origin) + " w=" + wide.width + " implicit=" + wide.implicitWidth;
        const fillOf = meter => root.findNamed(meter, "quotaBarFill").color;
        if (provider === "codex") {
            if (titles !== "5-hour|Weekly|5-hour|Weekly|5-hour" || left.join(",") !== "0,60,70,80,null")
                return "Codex readings: " + titles + " " + left.join(",");
            if (names.length !== 3)
                return "Codex account captions: " + names.length;
            if (!Qt.colorEqual(fillOf(meters[0]), Colours.palette.m3error))
                return "an empty (0% left) bar is not the error colour";
            if (!Qt.colorEqual(fillOf(meters[1]), Colours.palette.m3primary) || !Qt.colorEqual(fillOf(meters[3]), Colours.palette.m3primary))
                return "a healthy bar is not the primary colour";
            if (!root.hasText(section, /did not answer the quota request/)
                    || !root.hasText(section, /has not been reported/)
                    || !root.hasText(section, /^—$/))
                return "stale or unreported notice missing";
        } else if (provider === "claude") {
            if (titles !== "Weekly|Weekly" || left.join(",") !== "50,90")
                return "Claude readings: " + titles + " " + left.join(",");
            if (!root.hasText(section, /authorization needs attention/)
                    || !root.hasText(section, /Disabled in CPA/))
                return "reconnect or disabled notice missing";
        } else if (provider === "cursor") {
            if (titles !== "API|Auto" || left.join(",") !== "38,65")
                return "Cursor readings: " + titles + " " + left.join(",");
        } else if (provider === "zai") {
            if (titles !== "Monthly" || left.join(",") !== "73")
                return "Z.ai invented a window: " + titles + " " + left.join(",");
        } else {
            return "unexpected provider " + provider;
        }
        console.log("CAELESTIA_QUOTA_SMOKE_STATE", JSON.stringify({
            provider: provider, geometry: root.geometry, meters: meters.length, titles: titles, left: left.join(","),
            contentH: m.contentH, bodyH: m.bodyH
        }));
        return "";
    }

    function captureTo(path, then): void {
        if (!path) {
            then();
            return;
        }
        driver.busy = true;
        CUtils.saveItem(host, Qt.resolvedUrl(path), () => {
            console.log("CAELESTIA_QUOTA_SMOKE_CAPTURE", path);
            driver.busy = false;
            then();
        }, () => root.fail("screenshot"));
    }

    function applyLightPalette(): bool {
        if (!root.lightScreenshotPath || !root.lightSchemePath || !lightScheme.loaded)
            return false;
        Colours.load(lightScheme.text(), false);
        return Colours.light;
    }

    function closeDrawer(): void {
        root.screenState.quota = false;
        driver.step = 5;
        driver.retries = 0;
    }

    function setPanel(on: bool): void {
        GlobalConfig.windows = { quota: { enabled: on } };
    }

    Timer {
        id: driver

        property int step: 0
        property int retries: 0
        property int layoutRetries: 0
        property int groupIndex: 0
        property int phase: 0
        property bool busy: false
        property double requestStamp: 0

        interval: 200
        repeat: true
        running: root.selectedScreen !== null && root.screenState !== null
        onTriggered: root.advance()
    }

    function advance(): void {
        if (driver.busy)
            return;
        const panels = root.screenState ? panelsRoot : null;
        if (!panels) {
            root.fail("missing original drawer Panels");
            return;
        }
        const quota = panels.quota;
        if (!quota) {
            root.fail("quota drawer is not wired into Panels");
            return;
        }

        if (driver.step === 0) {
            if (bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                    || clockFont.status !== FontLoader.Ready)
                return;
            if (host.width !== root.previewWidth || host.height !== root.previewHeight)
                return;
            const off = root.mode === "disabled" || root.mode === "unconfigured";
            if (!off && (root.quotaRegion().width <= 0 || root.quotaRegion().height <= 0)) {
                root.fail("quota input region did not build");
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_REGION", JSON.stringify({
                width: root.quotaRegion().width, height: root.quotaRegion().height,
                quotaWidth: quota.width, quotaEnabled: panels.quotaEnabled
            }));

            if (root.mode === "disabled") {
                // A valid CPA config, with the setting off in shell.json.
                if (!Quota.configured || Quota.enabled || QuotaConfig.enabled || panels.quotaEnabled) {
                    root.fail("disabled run: configured=" + Quota.configured + " enabled=" + Quota.enabled + " panel=" + panels.quotaEnabled);
                    return;
                }
                // Nothing of the drawer is left: no input strip, and a hover that
                // asks for it (screenState.quota) cannot open it.
                if (root.quotaRegion().width !== 0 || root.quotaRegion().height !== 0) {
                    root.fail("disabled run kept an input region: " + root.quotaRegion().width + "x" + root.quotaRegion().height);
                    return;
                }
                root.screenState.quota = true;
                driver.step = 8;
                driver.phase = 0;
                driver.retries = 0;
                return;
            }

            if (root.mode === "unconfigured") {
                if (Quota.configured) {
                    root.fail("unconfigured run detected a CPA config");
                    return;
                }
                if (panels.quotaEnabled || root.quotaRegion().width !== 0 || root.quotaRegion().height !== 0) {
                    root.fail("quota drawer or its input region exists without a CPA config");
                    return;
                }
                if (Quota.providers.length !== 0 || Quota.loading || Quota.hasError
                        || Quota.status !== "unconfigured") {
                    root.fail("unconfigured service was not quiet: providers=" + Quota.providers.length
                        + " loading=" + Quota.loading + " status=" + Quota.status + " error=" + Quota.error);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_UNCONFIGURED", JSON.stringify({
                    status: Quota.status, configured: Quota.configured, enabled: Quota.enabled
                }));
                root.screenState.quota = true;
                driver.step = 5;
                driver.retries = 0;
                return;
            }

            if (root.mode === "offline") {
                if (Quota.loading || Quota.status !== "error") {
                    if (driver.retries++ < 50)
                        return;
                    root.fail("offline service did not settle: status=" + Quota.status
                        + " loading=" + Quota.loading + " error=" + Quota.error);
                    return;
                }
                if (!Quota.configured || !Quota.enabled) {
                    root.fail("offline run did not stay configured/enabled");
                    return;
                }
                if (!Quota.hasError) {
                    root.fail("offline run did not report a saved-data error");
                    return;
                }
                if (root.saved !== (Quota.providers.length > 0)) {
                    root.fail("offline saved-data expectation: saved=" + root.saved
                        + " providers=" + Quota.providers.length);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_OFFLINE", JSON.stringify({
                    status: Quota.status, error: Quota.error,
                    providers: Quota.providers.length, saved: root.saved
                }));
                root.screenState.quota = true;
                driver.step = 1;
                driver.retries = 0;
                return;
            }

            if (root.mode === "states") {
                if (Quota.providers.length !== 7) {
                    if (driver.retries++ < 60)
                        return;
                    root.fail("states summary did not load: status=" + Quota.status
                        + " providers=" + Quota.providers.length + " error=" + Quota.error);
                    return;
                }
                if (Quota.hasError || Quota.status !== "partial" || Quota.providerGroups.length !== 4) {
                    root.fail("states summary shape: status=" + Quota.status + " error=" + Quota.error
                        + " groups=" + Quota.providerGroups.length);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_STATES_SUMMARY", JSON.stringify({
                    status: Quota.status, providers: Quota.providers.length, groups: Quota.providerGroups.length
                }));
                root.screenState.quota = true;
                driver.step = 1;
                driver.retries = 0;
                return;
            }

            if (Quota.providers.length !== 5) {
                if (driver.retries++ < 60)
                    return;
                root.fail("quota summary did not load: status=" + Quota.status
                    + " configured=" + Quota.configured + " providers=" + Quota.providers.length
                    + " error=" + Quota.error);
                return;
            }
            if (!Quota.configured || !Quota.enabled || !panels.quotaEnabled) {
                root.fail("configured run did not detect/enable CPA");
                return;
            }
            if (Quota.hasError || Quota.status !== "ok") {
                root.fail("stub summary did not succeed: status=" + Quota.status + " error=" + Quota.error);
                return;
            }
            const claudeAccounts = Quota.providers.filter(account => account.provider === "claude");
            if (Quota.providerGroups.length !== 3 || claudeAccounts.length !== 2 || claudeAccounts[0].limits.length !== 3) {
                root.fail("provider grouping: groups=" + Quota.providerGroups.length
                    + " claudeAccounts=" + claudeAccounts.length);
                return;
            }
            if (Quota.todayCostUsd === null || Math.abs(Quota.todayCostUsd - 3.71) > 0.001) {
                root.fail("today's cost was not mapped: " + Quota.todayCostUsd);
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_SUMMARY", JSON.stringify({
                status: Quota.status, configured: Quota.configured, enabled: Quota.enabled,
                providers: Quota.providers.length, groups: Quota.providerGroups.length,
                claudeLimits: claudeAccounts[0].limits.length,
                scoped: claudeAccounts[0].limits.filter(l => String(l.title).indexOf("·") >= 0).length,
                todayCostUsd: Quota.todayCostUsd
            }));
            root.screenState.quota = true;
            driver.step = 1;
            driver.retries = 0;
            return;
        }

        if (driver.step === 1) {
            if (!quota.visible || quota.offsetScale > 0.01) {
                if (driver.retries++ < 40)
                    return;
                root.fail("quota drawer did not open: visible=" + quota.visible + " scale=" + quota.offsetScale);
                return;
            }
            // Opening a stale drawer starts another refresh. Wait for it to
            // settle so the offline frame shows the saved-data error, not the
            // in-flight "Updating" state.
            if (Quota.loading) {
                if (driver.retries++ < 50)
                    return;
                root.fail("quota service did not settle after opening");
                return;
            }
            if (quota.width !== QuotaConfig.panelWidth || quota.height <= 0) {
                root.fail("quota geometry: " + quota.width + "x" + quota.height);
                return;
            }
            const meters = root.named(quota, "quotaMeter").length;
            if (root.mode === "states") {
                if (meters < 2) {
                    root.fail("states meters did not render: " + meters);
                    return;
                }
                driver.step = 7;
                driver.groupIndex = 0;
                driver.retries = 0;
                return;
            }
            if (root.mode === "configured") {
                if (Quota.hasError || Quota.status !== "ok") {
                    root.fail("configured drawer lost its summary after opening");
                    return;
                }
                if (!Quota.spend.today || !Quota.spend.yesterday || !Quota.spend.month) {
                    if (driver.retries++ < 30)
                        return;
                    root.fail("per-provider spend did not load");
                    return;
                }
                const problem = root.allViewError(quota, "Codex|Claude|Z.ai") || root.spendError(quota);
                if (problem !== "") {
                    if (driver.layoutRetries++ < 20)
                        return;
                    root.fail("All Usage: " + problem);
                    return;
                }
                driver.layoutRetries = 0;
                // The service has to be quiet while the drawer is just sitting open.
                driver.requestStamp = Quota.lastRequestAt;
                const m = root.measure(quota);
                console.log("CAELESTIA_QUOTA_SMOKE_OPEN", JSON.stringify({
                    mode: root.mode, width: quota.width, height: quota.height, meters: meters,
                    status: Quota.status, error: Quota.error, geometry: root.geometry,
                    bar: m.barW[0], barX: m.barX[0], contentH: m.contentH, bodyH: m.bodyH
                }));
                driver.step = 2;
                driver.phase = 0;
                driver.retries = 0;
                return;
            }
            if (!Quota.hasError || Quota.status !== "error") {
                if (driver.retries++ < 50)
                    return;
                root.fail("offline drawer lost its saved-data error after opening");
                return;
            }
            if (root.saved && meters < 2) {
                if (driver.retries++ < 20)
                    return;
                root.fail("saved-data drawer rendered no meters: " + meters);
                return;
            }
            if (!root.saved && meters !== 0) {
                root.fail("offline quota rendered meters without a summary: " + meters);
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_OPEN", JSON.stringify({
                mode: root.mode, width: quota.width, height: quota.height, meters: meters,
                status: Quota.status, error: Quota.error
            }));
            driver.step = 99;
            root.captureTo(root.screenshotPath, () => root.closeDrawer());
            return;
        }

        // configured: capture All Usage, then Priority, then the footer menu.
        if (driver.step === 2) {
            if (driver.phase === 0) {
                driver.phase = 1;
                root.captureTo(root.screenshotPath, () => {});
                return;
            }
            if (driver.phase === 1) {
                Quota.usageView = "priority";
                driver.phase = 2;
                driver.retries = 0;
                return;
            }
            const problem = root.priorityError(quota);
            if (problem !== "") {
                if (driver.retries++ < 20)
                    return;
                root.fail("Priority: " + problem);
                return;
            }
            driver.phase = 0;
            driver.step = 3;
            root.captureTo(root.priorityScreenshotPath, () => {});
            return;
        }

        if (driver.step === 3) {
            const more = root.findNamed(quota, "quotaMore");
            const menu = root.findNamed(quota, "quotaMenu");
            if (driver.phase === 0) {
                Quota.usageView = "all";
                more.clicked();
                driver.phase = 1;
                driver.retries = 0;
                return;
            }
            if (driver.phase === 1) {
                const items = root.named(menu, "quotaMenuItem");
                if (!menu.visible || items.length !== 2 || items[0].modelData.key !== "refresh") {
                    if (driver.retries++ < 20)
                        return;
                    root.fail("footer menu did not open with Refresh now first: visible=" + menu.visible + " items=" + items.length);
                    return;
                }
                if (Quota.lastRequestAt !== driver.requestStamp) {
                    root.fail("opening the menu or switching views triggered a refresh");
                    return;
                }
                driver.phase = 2;
                root.captureTo(root.menuScreenshotPath, () => {});
                return;
            }
            if (driver.phase === 2) {
                menu.hide();
                if (menu.visible) {
                    root.fail("menu did not close");
                    return;
                }
                driver.phase = 0;
                if (root.applyLightPalette()) {
                    driver.step = 4;
                    driver.retries = 0;
                } else {
                    root.closeDrawer();
                }
            }
            return;
        }

        if (driver.step === 4) {
            if (!Colours.light) {
                if (driver.retries++ < 20)
                    return;
                root.fail("light palette did not load");
                return;
            }
            // Let the palette change repaint one frame before saving evidence.
            if (driver.retries++ < 2)
                return;
            driver.step = 99;
            root.captureTo(root.lightScreenshotPath, () => root.closeDrawer());
            return;
        }

        if (driver.step === 5) {
            if (quota.visible || quota.offsetScale < 0.99) {
                if (driver.retries++ < 40)
                    return;
                root.fail("quota drawer did not close: visible=" + quota.visible + " scale=" + quota.offsetScale);
                return;
            }
            if (root.mode === "unconfigured" && panels.quotaEnabled) {
                root.fail("unconfigured drawer became enabled");
                return;
            }
            driver.stop();
            console.log("CAELESTIA_QUOTA_SMOKE_PASS", root.mode);
            Qt.quit();
            return;
        }

        // States fixture: scroll to each provider section in turn.
        if (driver.step === 7) {
            const body = root.findNamed(quota, "quotaBody");
            const sections = root.named(body.contentItem, "quotaSection");
            if (sections.length !== 4) {
                if (driver.retries++ < 20)
                    return;
                root.fail("states sections: " + sections.length);
                return;
            }
            const provider = ["codex", "claude", "cursor", "zai"][driver.groupIndex];
            if (!provider) {
                root.closeDrawer();
                return;
            }
            const section = sections[driver.groupIndex];
            body.contentY = Math.max(0, Math.min(body.contentHeight - body.height, section.mapToItem(body.contentItem, 0, 0).y));
            if (driver.retries++ < 3)
                return;
            const problem = root.statesError(quota, driver.groupIndex, provider);
            if (problem !== "") {
                if (driver.layoutRetries++ < 20)
                    return;
                root.fail("states " + provider + ": " + problem);
                return;
            }
            driver.layoutRetries = 0;
            const base = root.screenshotPath;
            root.captureTo(base ? base.replace(/\.png$/, "-" + provider + ".png") : "", () => {
                driver.groupIndex++;
                driver.retries = 0;
            });
            return;
        }

        // Disabled: the setting is off, so nothing runs; then on, off and on at runtime.
        if (driver.step === 8) {
            if (driver.phase === 0) {
                if (driver.retries++ < 15)
                    return;
                if (quota.visible || quota.offsetScale !== 1) {
                    root.fail("a disabled drawer opened: visible=" + quota.visible + " scale=" + quota.offsetScale);
                    return;
                }
                if (Quota.lastRequestAt !== 0 || Quota.inFlight || Quota.loading || Quota.providers.length !== 0) {
                    root.fail("a disabled panel made a request: last=" + Quota.lastRequestAt + " inFlight=" + Quota.inFlight);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_DISABLED", JSON.stringify({
                    enabled: Quota.enabled, panel: panels.quotaEnabled, requests: Quota.lastRequestAt,
                    regionWidth: root.quotaRegion().width, regionHeight: root.quotaRegion().height
                }));
                root.screenState.quota = false;
                root.setPanel(true);
                driver.phase = 1;
                driver.retries = 0;
                return;
            }
            if (driver.phase === 1) {
                // On again, live: the service reads its endpoint and refreshes.
                if (!Quota.enabled || !panels.quotaEnabled || Quota.providers.length !== 5 || Quota.loading) {
                    if (driver.retries++ < 60)
                        return;
                    root.fail("enabling live did not start the service: enabled=" + Quota.enabled + " providers=" + Quota.providers.length);
                    return;
                }
                if (root.quotaRegion().width <= 0 || root.quotaRegion().height <= 0) {
                    root.fail("enabling live did not restore the input region");
                    return;
                }
                root.screenState.quota = true;
                driver.phase = 2;
                driver.retries = 0;
                return;
            }
            if (driver.phase === 2) {
                if (!quota.visible || quota.offsetScale > 0.01 || Quota.loading) {
                    if (driver.retries++ < 40)
                        return;
                    root.fail("the drawer did not open after enabling live");
                    return;
                }
                if (root.named(quota, "quotaMeter").length < 4) {
                    root.fail("the live-enabled drawer shows no meters");
                    return;
                }
                root.setPanel(false);
                driver.phase = 3;
                driver.retries = 0;
                return;
            }
            if (driver.phase === 3) {
                // Off again, live: the drawer closes, the region goes, the service stops.
                if (quota.visible || root.screenState.quota || Quota.inFlight || Quota.loading) {
                    if (driver.retries++ < 40)
                        return;
                    root.fail("disabling live did not close the drawer: visible=" + quota.visible
                        + " requested=" + root.screenState.quota + " inFlight=" + Quota.inFlight);
                    return;
                }
                if (root.quotaRegion().width !== 0 || root.quotaRegion().height !== 0) {
                    root.fail("disabling live kept the input region");
                    return;
                }
                driver.requestStamp = Quota.lastRequestAt;
                driver.phase = 4;
                driver.retries = 0;
                return;
            }
            if (driver.phase === 4) {
                if (driver.retries++ < 15)
                    return;
                if (Quota.lastRequestAt !== driver.requestStamp || Quota.inFlight) {
                    root.fail("a request ran after the panel was switched off");
                    return;
                }
                root.setPanel(true);
                driver.phase = 5;
                return;
            }
            if (driver.phase === 5) {
                // Back on: the cached reading is there at once, with nothing reopened.
                if (!Quota.enabled || Quota.providers.length !== 5 || quota.visible) {
                    root.fail("re-enabling lost the cache or reopened the drawer: providers=" + Quota.providers.length);
                    return;
                }
                driver.stop();
                console.log("CAELESTIA_QUOTA_SMOKE_PASS", root.mode);
                Qt.quit();
            }
            return;
        }
    }

    Timer {
        running: true
        interval: 85000
        onTriggered: {
            console.error("CAELESTIA_QUOTA_SMOKE_FAIL timeout");
            Qt.exit(1);
        }
    }
}
