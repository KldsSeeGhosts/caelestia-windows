// Windows CPA quota smoke host.
//
// Staged into the production graph by windows/scripts/Test-Quota.ps1 and run
// with an isolated profile and the offscreen platform. The offscreen QPA has no
// PanelWindow backend, so it instantiates the original drawer Panels and the
// ported Quota.Wrapper directly instead of ContentWindow. That still exercises
// the real staging, singleton service, panel layout, meters, provider marks and
// blur-blob surface.
//
//   * configured: a local synthetic CPA stub lets cpa_usage.py collect records;
//     the drawer opens, meters render, and the screenshot is saved;
//   * offline: the CPA endpoint is unreachable; the service must settle into one
//     friendly saved-data error, keep the drawer usable, and never hang;
//   * unconfigured: no cpa-agents.json exists; the service spawns no collector
//     and the drawer stays disabled.
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
    readonly property ShellScreen selectedScreen: Quickshell.screens[0] ?? null
    readonly property ScreenState screenState: ShellState.forScreen(root.selectedScreen)
    readonly property int inset: 60
    readonly property int previewWidth: Math.min(900, (selectedScreen?.width ?? 1060) - inset * 2)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - inset * 2)
    readonly property string screenshotPath: Quickshell.env("CAELESTIA_SHELL_SCREENSHOT")

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

    function capture(then): void {
        if (!root.screenshotPath) {
            then();
            return;
        }
        CUtils.saveItem(host, Qt.resolvedUrl(root.screenshotPath), () => {
            console.log("CAELESTIA_QUOTA_SMOKE_CAPTURE", root.screenshotPath);
            then();
        }, () => root.fail("screenshot"));
    }

    Timer {
        id: driver

        property int step: 0
        property int retries: 0
        property bool captured: false

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
                if (Quota.providers.length !== 0 || Quota.loading || Quota.hasError) {
                    root.fail("unconfigured service was not quiet: providers=" + Quota.providers.length
                        + " loading=" + Quota.loading + " error=" + Quota.error);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_UNCONFIGURED", JSON.stringify({
                    status: Quota.status, configured: Quota.configured, enabled: Quota.enabled
                }));
                root.screenState.quota = true;
                driver.step = 3;
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
                if (Quota.providers.length !== 0 || !Quota.hasError) {
                    root.fail("offline run did not report saved/empty data: providers="
                        + Quota.providers.length + " error=" + Quota.error);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_OFFLINE", JSON.stringify({
                    status: Quota.status, error: Quota.error, providers: Quota.providers.length
                }));
                root.screenState.quota = true;
                driver.step = 1;
                driver.retries = 0;
                return;
            }

            if (Quota.providers.length < 2) {
                if (driver.retries++ < 60)
                    return;
                root.fail("collector records did not load: status=" + Quota.status
                    + " configured=" + Quota.configured + " providers=" + Quota.providers.length
                    + " error=" + Quota.error);
                return;
            }
            if (!Quota.configured || !Quota.enabled) {
                root.fail("configured run did not detect/enable CPA");
                return;
            }
            if (Quota.hasError || Quota.status !== "ok") {
                root.fail("stub collection did not succeed: status=" + Quota.status + " error=" + Quota.error);
                return;
            }
            if (Quota.providerGroups.length !== 2 || Quota.activeGroupAccounts.length !== 1) {
                root.fail("provider grouping: groups=" + Quota.providerGroups.length
                    + " accounts=" + Quota.activeGroupAccounts.length);
                return;
            }
            const codex = Quota.providers.find(provider => provider.provider === "codex");
            const claude = Quota.providers.find(provider => provider.provider === "claude");
            if (!codex || codex.limits.length !== 2 || !claude || claude.limits.length !== 2) {
                root.fail("live limit rows: codex=" + (codex ? codex.limits.length : -1)
                    + " claude=" + (claude ? claude.limits.length : -1));
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_RECORDS", JSON.stringify({
                status: Quota.status, configured: Quota.configured, enabled: Quota.enabled,
                providers: Quota.providers.length, groups: Quota.providerGroups.length,
                codexLimits: codex.limits.length, claudeLimits: claude.limits.length,
                todayTokens: Quota.todayTotalTokens
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
            if (root.mode === "offline" && (!Quota.hasError || Quota.status !== "error")) {
                if (driver.retries++ < 50)
                    return;
                root.fail("offline drawer lost its saved-data error after opening");
                return;
            }
            if (quota.width !== QuotaConfig.panelWidth || quota.height <= 0) {
                root.fail("quota geometry: " + quota.width + "x" + quota.height);
                return;
            }
            const meters = root.countMeters(quota);
            if (root.mode === "configured" && meters < 2) {
                root.fail("quota meters did not render: " + meters);
                return;
            }
            if (root.mode === "offline" && meters !== 0) {
                root.fail("offline quota rendered meters without records: " + meters);
                return;
            }
            console.log("CAELESTIA_QUOTA_SMOKE_OPEN", JSON.stringify({
                mode: root.mode, width: quota.width, height: quota.height, meters: meters,
                status: Quota.status, error: Quota.error, provider: Quota.activeProvider?.provider ?? ""
            }));
            if (root.mode === "configured") {
                const claude = Quota.providers.find(provider => provider.provider === "claude");
                Quota.selectProvider(claude.id);
                driver.step = 2;
                driver.retries = 0;
                return;
            }
            driver.step = 2;
            driver.retries = 0;
            return;
        }

        if (driver.step === 2) {
            // saveItem is asynchronous; keep the driver from starting a second
            // capture on the next tick.
            if (driver.captured)
                return;
            driver.captured = true;
            if (root.mode === "configured") {
                if (!Quota.activeProvider || Quota.activeProvider.provider !== "claude") {
                    root.fail("account selection did not switch to Claude");
                    return;
                }
                const meters = root.countMeters(quota);
                if (meters < 2) {
                    root.fail("Claude meters did not render: " + meters);
                    return;
                }
                console.log("CAELESTIA_QUOTA_SMOKE_SWITCH", JSON.stringify({
                    provider: Quota.activeProvider.provider,
                    label: Quota.activeGroup?.label ?? "",
                    accounts: Quota.activeGroupAccounts.length,
                    meters: meters
                }));
            }
            root.capture(() => {
                root.screenState.quota = false;
                driver.step = 3;
                driver.retries = 0;
            });
            return;
        }

        if (driver.step === 3) {
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
