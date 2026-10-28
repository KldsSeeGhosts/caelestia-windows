// Windows CPA quota smoke host.
//
// Staged into the production graph by windows/scripts/Test-Quota.ps1 and run
// with an isolated profile and the offscreen platform. The offscreen QPA has no
// PanelWindow backend, so it instantiates the original drawer Panels (which
// creates Quota.Wrapper) instead of ContentWindow. That still exercises the real
// staging, singleton service, panel layout, meters and provider marks.
//
//   * configured: a local synthetic CPA Manager stub serves the pre-aggregated
//     quota summary; the drawer opens on the Claude group, the model-scoped
//     window, provider sections and spend card render, and dark/light screenshots are
//     saved;
//   * offline: the endpoint refuses connections and, when the configured run
//     left a cached summary, the drawer keeps that reading with the one friendly
//     saved-data line; it must never hang;
//   * unconfigured: no cpa-agents.json exists; the service makes no request and
//     the drawer stays disabled.
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
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - inset * 2)
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
                color: Colours.palette.m3surface
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

    // Count the original QuotaMeter items in the open detail column.
    function countMeters(item): int {
        let count = 0;
        for (const child of item.children) {
            if (child && child.limit !== undefined && child.remaining !== undefined)
                count++;
            count += root.countMeters(child);
        }
        return count;
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

    function scopedWindows(accounts): int {
        let count = 0;
        for (const account of accounts) {
            for (const limit of account.limits || []) {
                if (String(limit.title || "").indexOf("·") >= 0)
                    count++;
            }
        }
        return count;
    }

    function captureTo(path, then): void {
        if (!path) {
            then();
            return;
        }
        CUtils.saveItem(host, Qt.resolvedUrl(path), () => {
            console.log("CAELESTIA_QUOTA_SMOKE_CAPTURE", path);
            then();
        }, () => root.fail("screenshot"));
    }

    function capture(then): void {
        root.captureTo(root.screenshotPath, then);
    }

    function captureLight(then): void {
        root.captureTo(root.lightScreenshotPath, then);
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

    Timer {
        id: driver

        property int step: 0
        property int retries: 0
        property bool captured: false
        property bool lightCaptured: false

        interval: 200
        repeat: true
        running: root.selectedScreen !== null && root.screenState !== null
        onTriggered: root.advance()
    }

    function advance(): void {
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
            if (root.quotaRegions.width <= 0 || root.quotaRegions.height <= 0) {
                root.fail("quota input region did not build");
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_REGION", JSON.stringify({
                width: root.quotaRegions.width, height: root.quotaRegions.height,
                quotaWidth: quota.width, quotaEnabled: panels.quotaEnabled
            }));

            if (root.mode === "unconfigured") {
                if (Quota.configured) {
                    root.fail("unconfigured run detected a CPA config");
                    return;
                }
                if (panels.quotaEnabled) {
                    root.fail("quota drawer enabled without a CPA config");
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

            if (Quota.providers.length !== 5) {
                if (driver.retries++ < 60)
                    return;
                root.fail("quota summary did not load: status=" + Quota.status
                    + " configured=" + Quota.configured + " providers=" + Quota.providers.length
                    + " error=" + Quota.error);
                return;
            }
            if (!Quota.configured || !Quota.enabled) {
                root.fail("configured run did not detect/enable CPA");
                return;
            }
            if (Quota.hasError || Quota.status !== "ok") {
                root.fail("stub summary did not succeed: status=" + Quota.status + " error=" + Quota.error);
                return;
            }
            const claudeAccounts = Quota.providers.filter(account => account.provider === "claude");
            if (Quota.providerGroups.length !== 3 || Quota.activeGroupAccounts.length !== 2) {
                root.fail("provider grouping: groups=" + Quota.providerGroups.length
                    + " codexAccounts=" + Quota.activeGroupAccounts.length);
                return;
            }
            if (claudeAccounts.length !== 2 || claudeAccounts[0].limits.length !== 3) {
                root.fail("Claude quota rows: accounts=" + claudeAccounts.length
                    + " limits=" + (claudeAccounts.length ? claudeAccounts[0].limits.length : -1));
                return;
            }
            if (root.scopedWindows(claudeAccounts) !== 1) {
                root.fail("model-scoped window was not classified: " + root.scopedWindows(claudeAccounts));
                return;
            }
            if (Quota.todayCostUsd === null || Math.abs(Quota.todayCostUsd - 3.71) > 0.001) {
                root.fail("today's cost was not mapped: " + Quota.todayCostUsd);
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_SUMMARY", JSON.stringify({
                status: Quota.status, configured: Quota.configured, enabled: Quota.enabled,
                providers: Quota.providers.length, groups: Quota.providerGroups.length,
                accounts: Quota.providers.length, claudeLimits: claudeAccounts[0].limits.length,
                scoped: root.scopedWindows(claudeAccounts), todayCostUsd: Quota.todayCostUsd
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
            // in-flight "Refreshing" state.
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
            const meters = root.countMeters(quota);
            if (root.mode === "configured") {
                if (Quota.hasError || Quota.status !== "ok") {
                    root.fail("configured drawer lost its summary after opening");
                    return;
                }
                if (meters < 2) {
                    root.fail("quota meters did not render: " + meters);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_OPEN", JSON.stringify({
                    mode: root.mode, width: quota.width, height: quota.height, meters: meters,
                    status: Quota.status, error: Quota.error, provider: Quota.activeProvider?.provider ?? ""
                }));
                const claude = Quota.providers.find(account => account.provider === "claude");
                Quota.selectProvider(claude.id);
                driver.step = 2;
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
            if (driver.captured)
                return;
            console.log("CAELESTIA_QUOTA_SMOKE_OPEN", JSON.stringify({
                mode: root.mode, width: quota.width, height: quota.height, meters: meters,
                status: Quota.status, error: Quota.error,
                provider: Quota.activeProvider?.provider ?? ""
            }));
            driver.captured = true;
            root.capture(() => root.closeDrawer());
            return;
        }

        if (driver.step === 2) {
            if (!Quota.activeProvider || Quota.activeProvider.provider !== "claude") {
                if (driver.retries++ < 20)
                    return;
                root.fail("account selection did not switch to Claude");
                return;
            }
            const content = root.findContent(quota);
            if (!content) {
                root.fail("quota Content root was not found");
                return;
            }
            driver.step = 3;
            driver.retries = 0;
            return;
        }

        if (driver.step === 3) {
            if (driver.captured)
                return;
            const content = root.findContent(quota);
            const amount = root.findNamed(quota, "quotaSpendAmount");
            if (!Quota.spend.today || !Quota.spend.yesterday || !Quota.spend.month) {
                if (driver.retries++ < 20)
                    return;
                root.fail("per-provider spend did not load");
                return;
            }
            if (!content || !content.revealed || !root.findNamed(quota, "quotaSpend")
                    || !root.findNamed(quota, "quotaSection") || !amount || amount.text !== "$3.71"
                    || Quota.spend.month.rows.length !== 6) {
                root.fail("spend card or provider sections did not render");
                return;
            }
            const meters = root.countMeters(quota);
            if (meters < 3) {
                root.fail("Claude meters did not render: " + meters);
                return;
            }
            if (root.lightScreenshotPath && root.lightSchemePath && !lightScheme.loaded) {
                if (driver.retries++ < 20)
                    return;
                root.fail("light scheme fixture did not load");
                return;
            }
            driver.retries = 0;
            console.log("CAELESTIA_QUOTA_SMOKE_SWITCH", JSON.stringify({
                provider: Quota.activeProvider.provider,
                label: Quota.activeGroup?.label ?? "",
                accounts: Quota.activeGroupAccounts.length,
                meters: meters, scoped: root.scopedWindows(Quota.activeGroupAccounts),
                sectionsAndSpend: true, todayCostUsd: Quota.todayCostUsd
            }));
            driver.captured = true;
            root.capture(() => {
                if (root.applyLightPalette()) {
                    driver.step = 4;
                    driver.retries = 0;
                } else {
                    root.closeDrawer();
                }
            });
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
            if (driver.lightCaptured)
                return;
            driver.lightCaptured = true;
            const content = root.findContent(quota);
            if (!content || !content.revealed) {
                root.fail("drawer closed before the light capture");
                return;
            }
            root.captureLight(() => root.closeDrawer());
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
        }
    }

    Timer {
        running: true
        interval: 55000
        onTriggered: {
            console.error("CAELESTIA_QUOTA_SMOKE_FAIL timeout");
            Qt.exit(1);
        }
    }
}
