//@ pragma AppId org.caelestia.windows-tray-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services
import qs.modules.bar.components as BarComponents
import qs.modules.bar.popouts as BarPopouts

// A separate bounded M2 host for the original bar tray components. The native
// SystemTray is constructed only through the CAELESTIA_WINDOWS_TRAY opt-in, and
// this launcher forces QS_WINDOWS_TRAY_HOOK=0 so observation never starts tray
// interception. No bar, popout wrapper, drawer, taskbar or other service is
// loaded. Smoke never enables activation; the fixture mode renders plain objects
// and never references the native tray.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property bool fixture: Quickshell.env("CAELESTIA_TRAY_FIXTURE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(660, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(600, (selectedScreen?.height ?? 780) - 160)

    property var initialTrayState: null
    property bool failed: false

    // The original popout state object; TrayMenu only needs hasCurrent and the
    // original component shape. The semantic menu never renders with the pinned
    // backend because every menu handle is null.
    readonly property BarPopouts.PopoutState popoutState: BarPopouts.PopoutState {}

    // Plain objects stand in for SystemTrayItem delegates. They never reference
    // the native singleton and their command methods are inert; no fixture item
    // is clicked.
    readonly property string fixtureIcon: Qt.resolvedUrl("fixtures/tray-icon.png")
    readonly property var fixtureItems: [
        {
            id: "fixture.one", title: "Fixture One", status: 1, hasMenu: true,
            menu: null, icon: root.fixtureIcon,
            activate: function () {}, secondaryActivate: function () {}, display: function () {}
        },
        {
            id: "fixture.two", title: "Fixture Two", status: 2, hasMenu: true,
            menu: null, icon: root.fixtureIcon,
            activate: function () {}, secondaryActivate: function () {}, display: function () {}
        },
        {
            id: "fixture.three", title: "Fixture Three", status: 1, hasMenu: true,
            menu: null, icon: root.fixtureIcon,
            activate: function () {}, secondaryActivate: function () {}, display: function () {}
        }
    ]

    settings.watchFiles: false

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_TRAY_FAIL: " + message);
        Qt.exit(1);
    }

    function renderedTitles(): var {
        const tray = trayHost.item;
        if (!tray)
            return [];

        const result = [];
        for (let i = 0; i < tray.items.count; i++) {
            const delegate = tray.items.itemAt(i);
            result.push(delegate ? Tray.itemTitle(delegate.modelData) : "");
        }
        return result;
    }

    function trayState(): var {
        const tray = trayHost.item;
        const menu = menuHost.item;
        const first = Tray.list.length > 0 ? Tray.list[0] : null;
        const firstDelegate = tray && tray.items.count > 0 ? tray.items.itemAt(0) : null;
        return {
            smoke: root.smoke, fixture: root.fixture,
            status: Tray.status, reason: Tray.reason, enabled: Tray.enabled,
            activationEnabled: Tray.activationEnabled,
            nativeRequested: Tray.nativeRequested,
            backendLoaded: Tray.backend !== null,
            backendError: Tray.backendError, lastError: Tray.lastError,
            ready: Tray.ready, count: Tray.count, titles: Tray.titles, ids: Tray.ids,
            interceptionEnabled: Tray.interceptionEnabled,
            hookMode: Quickshell.env("QS_WINDOWS_TRAY_HOOK") ?? "",
            menuMode: Tray.menuMode,
            menuCoordinatesSupported: Tray.menuCoordinatesSupported,
            scrollSupported: Tray.scrollSupported,
            semanticMenuAvailable: Tray.semanticMenuAvailable,
            listGeneration: Tray.listGeneration, listResets: Tray.listResets,
            peakCount: Tray.peakCount, lastResetKind: Tray.lastResetKind,
            activationRequests: Tray.activationRequests,
            activationRefusals: Tray.activationRefusals,
            lastActivationResult: Tray.lastActivationResult,
            lastActivationReason: Tray.lastActivationReason,
            menuRequests: Tray.menuRequests, menuShown: Tray.menuShown,
            menuRefusals: Tray.menuRefusals,
            lastMenuResult: Tray.lastMenuResult, lastMenuReason: Tray.lastMenuReason,
            staleRequests: Tray.staleRequests, scrollRequests: Tray.scrollRequests,
            firstId: Tray.itemId(first), firstTitle: Tray.itemTitle(first),
            firstHasMenu: Tray.hasMenu(first),
            firstMenuHandleNull: Tray.menuHandle(first) === null,
            firstRenderableMenu: Tray.hasRenderableMenu(first),
            trayLoaded: tray !== null,
            trayActive: trayHost.active,
            renderedCount: tray ? tray.items.count : 0,
            renderedTitles: root.renderedTitles(),
            firstDelegated: firstDelegate !== null,
            firstItemInteractions: firstDelegate ? firstDelegate.interactionsEnabled : null,
            firstItemNativeMenu: firstDelegate ? firstDelegate.nativeMenuMode : null,
            firstIconReady: firstDelegate ? firstDelegate.iconItem.status === Image.Ready : null,
            firstIconLayer: firstDelegate ? firstDelegate.iconItem.layer.enabled : null,
            firstIconTint: firstDelegate ? String(firstDelegate.iconItem.colour) : "",
            expectedTint: String(Colours.palette.m3secondary),
            menuLoaded: menu !== null,
            menuActive: menuHost.active,
            menuSemanticAvailable: menu ? menu.semanticMenuAvailable : null,
            menuNotice: menu && menu.currentItem ? (menu.currentItem.notice ?? "") : "",
            menuNoticeColour: menu && menu.currentItem && menu.currentItem.noticeColour
                ? String(menu.currentItem.noticeColour) : "",
            expectedDisabledColour: String(Colours.palette.m3outline)
        };
    }

    function checkPolicy(state): void {
        const expectedEnabled = Quickshell.env("CAELESTIA_WINDOWS_TRAY") === "1";
        const expectedActivation = expectedEnabled
            && Quickshell.env("CAELESTIA_WINDOWS_TRAY_ACTIVATION") === "1";
        if (state.enabled !== expectedEnabled || state.activationEnabled !== expectedActivation) {
            root.fail("service opt-in policy");
            return;
        }
        if (state.activationEnabled) {
            root.fail("smoke run enabled tray activation");
            return;
        }
        // The launcher must force the backend hook off for the whole slice.
        if (state.hookMode !== "0") {
            root.fail("QS_WINDOWS_TRAY_HOOK was not forced to 0");
            return;
        }
        if (state.interceptionEnabled) {
            root.fail("interception is advertised as enabled");
            return;
        }
        if (state.menuMode !== "native" || state.menuCoordinatesSupported || state.scrollSupported) {
            root.fail("native-only menu or unsupported scroll policy mismatch");
            return;
        }
        if (state.fixture !== (Quickshell.env("CAELESTIA_TRAY_FIXTURE") === "1")) {
            root.fail("fixture policy mismatch");
            return;
        }
    }

    function checkInitialState(state): void {
        root.checkPolicy(state);
        if (root.failed)
            return;

        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready) {
            root.fail("UI, fonts or DPI");
            return;
        }

        if (state.fixture) {
            // Fixture preview: no native observation at all, original
            // components instantiated with plain objects.
            if (state.enabled || state.nativeRequested || state.backendLoaded
                    || state.trayLoaded !== true || state.renderedCount !== 3) {
                root.fail("fixture mode constructed the native backend or missed the fixture delegates");
                return;
            }
            if (state.menuLoaded !== true) {
                root.fail("fixture mode did not load the original tray menu");
                return;
            }
        } else if (!state.enabled) {
            if (state.status !== "disabled" || state.nativeRequested || state.backendLoaded
                    || state.trayLoaded || state.menuLoaded) {
                root.fail("disabled mode constructed the backend or original components");
                return;
            }
        } else {
            if (!state.nativeRequested) {
                root.fail("enabled mode did not activate the native backend loader");
                return;
            }
            if (state.trayLoaded !== true || state.menuLoaded !== true) {
                root.fail("enabled mode did not load the original tray components");
                return;
            }
            if (["initializing", "empty", "ready", "unavailable"].indexOf(state.status) < 0) {
                root.fail("tray service did not start: " + state.status);
                return;
            }
        }

        root.initialTrayState = state;
        console.log("CAELESTIA_TRAY_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_TRAY_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (state.fixture) {
            if (state.renderedCount !== 3
                    || JSON.stringify(state.renderedTitles)
                    !== JSON.stringify(["Fixture One", "Fixture Two", "Fixture Three"])) {
                root.fail("fixture delegates do not match the injected items");
                return;
            }
            if (state.firstItemInteractions !== false || state.firstItemNativeMenu !== false) {
                root.fail("fixture delegates are interactive");
                return;
            }
            if (state.firstIconReady !== true) {
                root.fail("fixture icon did not render");
                return;
            }
            if (state.firstIconLayer !== true) {
                root.fail("original ColouredIcon tinting layer is disabled");
                return;
            }
            if (state.firstIconTint !== state.expectedTint) {
                root.fail("original ColouredIcon tint colour changed");
                return;
            }
        } else if (state.enabled) {
            if (["empty", "ready", "unavailable"].indexOf(state.status) < 0) {
                root.fail("tray service did not settle: " + state.status);
                return;
            }
            if (state.status === "unavailable" && state.lastError === "") {
                root.fail("unavailable backend did not expose an error");
                return;
            }
            if (state.status !== "unavailable" && state.lastError !== "") {
                root.fail("healthy observation retained an error");
                return;
            }
            if ((state.status === "ready") !== (state.count > 0)) {
                root.fail("count and status disagree");
                return;
            }
            if (state.renderedCount !== state.count) {
                root.fail("original tray did not render every observed item");
                return;
            }
            if (state.count > 0) {
                if (state.firstHasMenu !== true || state.firstMenuHandleNull !== true
                        || state.firstRenderableMenu !== false) {
                    root.fail("hasMenu/menu=null contract is not represented");
                    return;
                }
                if (state.firstItemInteractions !== false || state.firstItemNativeMenu !== false) {
                    root.fail("read-only observation left item interactions enabled");
                    return;
                }
            }
            // Read-only observation must refuse every native request even when
            // the host tries to send one, without touching the real tray icons.
            const first = Tray.list.length > 0 ? Tray.list[0] : null;
            const activated = Tray.activate(first);
            const secondary = Tray.secondaryActivate(first);
            const menu = Tray.openMenu(first, win.contentItem, 10, 20);
            const scrolled = Tray.scroll(first, 120, false);
            if (activated || secondary || menu || scrolled) {
                root.fail("read-only observation forwarded a native request");
                return;
            }
            if (Tray.activationRequests !== 0 || Tray.menuShown !== 0) {
                root.fail("read-only request accounting is wrong");
                return;
            }
            if (Tray.lastActivationResult !== "refused" || Tray.lastMenuResult !== "refused") {
                root.fail("read-only refusals were not recorded");
                return;
            }
        } else if (state.status !== "disabled") {
            root.fail("disabled service did not settle: " + state.status);
            return;
        }

        if (state.menuLoaded) {
            if (state.menuSemanticAvailable !== false) {
                root.fail("a semantic tray menu was claimed without a handle");
                return;
            }
            if (state.menuNotice.length === 0
                    || state.menuNoticeColour !== state.expectedDisabledColour) {
                root.fail("unavailable menu did not use the existing disabled styling");
                return;
            }
        }
    }

    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }

    StyledWindow {
        id: win

        name: "tray-prototype"
        screen: root.selectedScreen
        visible: root.selectedScreen !== null
        implicitWidth: root.previewWidth
        implicitHeight: root.previewHeight
        anchors.top: true
        anchors.left: true
        margins.top: 80
        margins.left: 80
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: root.smoke ? WlrKeyboardFocus.None : WlrKeyboardFocus.OnDemand
        mask: root.smoke ? noInput : null
        color: Colours.palette.m3surface

        StyledRect {
            anchors.fill: parent
            color: Colours.palette.m3surface
        }

        Region { id: noInput }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    text: "Caelestia Windows tray"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                StyledText {
                    text: Tray.status + (root.fixture ? " (fixture)" : "")
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: root.fixture
                    ? "Fixture preview of the original bar tray components. No native tray is constructed and no item is clicked."
                    : Tray.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 24

                ColumnLayout {
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    StyledText {
                        text: "Original bar tray"
                        font: Tokens.font.label.medium
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledRect {
                        Layout.preferredWidth: trayHost.item
                            ? trayHost.item.implicitWidth + Tokens.padding.small * 2 : Tokens.sizes.bar.innerWidth
                        Layout.preferredHeight: trayHost.item ? trayHost.item.implicitHeight : 0
                        color: Colours.palette.m3surfaceContainer
                        radius: Tokens.rounding.full

                        // The original bar tray. It receives the observed item
                        // list (or fixture objects) through the localized
                        // sourceItems hook; upstream uses SystemTray directly.
                        Loader {
                            id: trayHost

                            anchors.centerIn: parent
                            active: Tray.enabled || root.fixture
                            sourceComponent: BarComponents.Tray {
                                sourceItems: root.fixture ? root.fixtureItems : Tray.list
                                itemInteractionsEnabled: Tray.activationEnabled
                                itemNativeMenuMode: Tray.activationEnabled
                                onItemMenuRequested: (item, x, y) => Tray.openMenu(item, win.contentItem, x, y)
                            }
                        }
                    }

                    StyledText {
                        text: root.fixture
                            ? "3 fixture icons, original spacing/motion"
                            : "icons: " + Tray.count
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    StyledText {
                        text: "Semantic tray menu"
                        font: Tokens.font.label.medium
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    // The backend reports hasMenu=true with menu=null, so the
                    // original TrayMenu renders its unavailable state with the
                    // existing disabled-entry colour. "Open menu" is routed to
                    // SystemTrayItem.display() only under the activation opt-in.
                    Loader {
                        id: menuHost

                        Layout.preferredWidth: Tokens.sizes.bar.trayMenuWidth
                        Layout.preferredHeight: item ? item.implicitHeight : 0
                        active: Tray.enabled || root.fixture
                        sourceComponent: BarPopouts.TrayMenu {
                            width: Tokens.sizes.bar.trayMenuWidth
                            popouts: root.popoutState
                            trayItem: Tray.list.length > 0 ? Tray.menuHandle(Tray.list[0]) : null
                            semanticMenuAvailable: Tray.semanticMenuAvailable
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: root.fixture || Tray.count === 0
                            ? "No tray item is observed, so no semantic menu exists. Right-click in the bar routes to the native context menu under the activation opt-in."
                            : "Observed: " + Tray.titles.join(", ")
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Read-only observation. Activation, the native context menu and scroll are "
                    + (Tray.activationEnabled ? "enabled by policy." : "disabled; scroll is unsupported.")
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }
        }

        Shortcut {
            sequence: "Escape"
            enabled: !root.smoke
            onActivated: Qt.quit()
        }
    }

    IpcHandler {
        target: "prototype"
        function state(): string {
            return JSON.stringify(root.trayState());
        }
        function quit(): void { Qt.quit(); }
    }

    Component.onCompleted: {
        if (!selectedScreen)
            Qt.callLater(() => Qt.exit(1));
    }

    Timer {
        id: check
        property int step
        running: root.smoke && root.selectedScreen !== null
        repeat: true
        interval: 1000
        onTriggered: {
            if (root.failed)
                return;
            if (!root.fixture && Tray.enabled && Tray.status === "initializing")
                return;
            if (root.fixture && trayHost.item) {
                // Wait for the original ColouredIcon's asynchronous load instead
                // of judging an intermediate frame.
                const delegate = trayHost.item.items.count > 0
                    ? trayHost.item.items.itemAt(0) : null;
                if (delegate) {
                    if (delegate.iconItem.status === Image.Error) {
                        root.fail("fixture icon failed to load");
                        return;
                    }
                    if (delegate.iconItem.status !== Image.Ready)
                        return;
                }
            }
            const state = root.trayState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialTrayState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_TRAY_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_TRAY_CAPTURE", path);
                    console.log("CAELESTIA_TRAY_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_TRAY_FAIL: screenshot");
                    Qt.exit(1);
                });
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 15000
        onTriggered: {
            console.error("CAELESTIA_TRAY_FAIL: timeout", Tray.status, Tray.reason);
            Qt.exit(1);
        }
    }
}
