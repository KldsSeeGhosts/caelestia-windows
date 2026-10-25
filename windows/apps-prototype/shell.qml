//@ pragma AppId org.caelestia.windows-apps-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import qs.modules.launcher
import qs.modules.launcher.services

// Bounded M2 host for the original launcher app list and search bar. The
// catalog/search adapter is default-off; enumeration is read-only and app
// launch requires a second opt-in. Actions, calculator, schemes, variants,
// wallpapers and every shell controller stay unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(560, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(560, (selectedScreen?.height ?? 780) - 160)
    readonly property int listCount: listLoader.item ? listLoader.item.count : 0
    property var screenStateObject: null
    property var initialState: null
    property bool failed: false

    settings.watchFiles: false

    function appsState(): var {
        const query = searchBar.text;
        const results = Apps.search(query);
        return {
            status: Apps.status, reason: Apps.reason, enabled: Apps.enabled,
            launchEnabled: Apps.launchEnabled,
            nativeRequested: Apps.nativeRequested, storeRequested: Apps.storeRequested,
            backendLoaded: Apps.backendLoaded,
            scanning: Apps.scanning, empty: Apps.empty, failed: Apps.failed,
            disabled: Apps.disabled, ready: Apps.ready, lastError: Apps.lastError,
            persistentFrequencies: Apps.frequencyStore ? Apps.frequencyStore.persistent : false,
            frequencyPath: Apps.frequencyStore ? Apps.frequencyStore.resolvedPath : "",
            count: Apps.count, listLoaded: listLoader.item !== null, listCount: root.listCount,
            query: query, queryCount: results.length,
            queryNames: results.slice(0, 6).map(entry => Apps.nameFor(entry)),
            queryIcons: results.slice(0, 6).map(entry => Apps.iconName(entry)),
            catalogNames: Apps.list.slice(0, 6).map(item => item.name),
            catalogIds: Apps.list.slice(0, 6).map(item => item.id),
            launchRequests: Apps.launchRequests, launchesIssued: Apps.launchesIssued,
            lastLaunchError: Apps.lastLaunchError,
            terminalLaunchSupported: Apps.terminalLaunchSupported,
            searchMatchesList: root.listCount === results.length
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_APPS_FAIL: " + message);
        Qt.exit(1);
    }

    function statusIcon(): string {
        switch (Apps.status) {
        case "disabled": return "apps";
        case "failed": return "error";
        default: return "manage_search";
        }
    }

    function emptyTitle(): string {
        return Apps.status === "ready" ? "No results" : Apps.statusTitle;
    }

    function emptyDescription(): string {
        return Apps.status === "ready"
            ? "Try searching for something else" : Apps.statusDescription;
    }

    // Smoke enters its fixed query through this host's own state, never through
    // synthesized pointer/keyboard input.
    function applySmokeQuery(): void {
        const requested = Quickshell.env("CAELESTIA_APPS_SMOKE_QUERY") || "";
        const first = Apps.list.length > 0 ? Apps.list[0].name : "";
        searchBar.text = requested.length > 0 ? requested : (first.length > 0 ? first.charAt(0) : "a");
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_APPS") === "1")
                || state.launchEnabled !== (state.enabled
                    && Quickshell.env("CAELESTIA_WINDOWS_APP_LAUNCH") === "1")) {
            root.fail("UI, fonts, DPI or service opt-in policy");
            return;
        }
        if (state.enabled) {
            if (!state.nativeRequested || !state.backendLoaded) {
                root.fail("enabled mode did not activate the native catalog loader");
                return;
            }
            if (!state.listLoaded || listLoader.item === null) {
                root.fail("original launcher app list did not load");
                return;
            }
            if (!state.persistentFrequencies) {
                root.fail("frequency store is not profile-persistent");
                return;
            }
        } else if (state.status !== "disabled" || state.nativeRequested
                || state.backendLoaded || state.listLoaded || listLoader.item !== null) {
            root.fail("disabled mode constructed the catalog or original list");
            return;
        }
        root.initialState = state;
        console.log("CAELESTIA_APPS_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_APPS_INITIAL", JSON.stringify(state));
    }

    function checkSearchState(state): void {
        console.log("CAELESTIA_APPS_SEARCH", JSON.stringify({
            query: state.query, queryCount: state.queryCount,
            queryNames: state.queryNames, queryIcons: state.queryIcons,
            listCount: state.listCount, listMatchesQuery: state.searchMatchesList,
            totalCount: state.count
        }));
    }

    function checkSettledState(state): void {
        if (!state.enabled) {
            const clean = state.status === "disabled" && !state.nativeRequested
                && !state.backendLoaded && !state.listLoaded
                && state.count === 0 && state.queryCount === 0 && state.listCount === 0;
            if (!clean) {
                root.fail("disabled service did not settle clean: " + state.status);
                return;
            }
        } else {
            if (["ready", "empty", "failed"].indexOf(state.status) < 0) {
                root.fail("enabled service did not settle: " + state.status);
                return;
            }
            // Smoke is always read-only and never launches.
            if (state.launchEnabled) {
                root.fail("smoke enabled app launching");
                return;
            }
            if (state.launchRequests !== 0 || state.launchesIssued !== 0
                    || state.lastLaunchError !== "") {
                root.fail("smoke issued a launch request");
                return;
            }
            if (state.terminalLaunchSupported) {
                root.fail("terminal launch advertised as supported");
                return;
            }
            if (state.ready) {
                if (state.count <= 0 || state.catalogNames.length === 0
                        || state.catalogNames[0].length === 0) {
                    root.fail("ready catalog has no named applications");
                    return;
                }
                if (state.queryCount > state.count) {
                    root.fail("search returned more results than the catalog");
                    return;
                }
                if (!state.searchMatchesList) {
                    root.fail("original app list count disagrees with search");
                    return;
                }
                for (const icon of state.queryIcons) {
                    if (icon.length === 0) {
                        root.fail("missing icon did not fall back");
                        return;
                    }
                }
            } else if (state.count !== 0 || state.queryCount !== 0
                    || state.listCount !== 0 || state.catalogNames.length !== 0) {
                root.fail("non-ready catalog invented applications");
                return;
            }
            if (state.status === "failed" && state.lastError.length === 0) {
                root.fail("failed catalog did not expose an error");
                return;
            }
        }
        console.log("CAELESTIA_APPS_FINAL", JSON.stringify(state));
    }

    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }

    readonly property Component screenStateComponent: Component {
        ScreenState {
            launcher: true
        }
    }

    StyledWindow {
        id: win

        name: "apps-prototype"
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

        Item {
            id: content

            anchors.fill: parent
            anchors.margins: 24

            Row {
                id: header

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right

                StyledText {
                    text: "Caelestia Windows apps"
                    font: Tokens.font.body.large
                    width: parent.width - statusLabel.width
                }

                StyledText {
                    id: statusLabel

                    text: Apps.status
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                id: reason

                anchors.top: header.bottom
                anchors.topMargin: 8
                anchors.left: parent.left
                anchors.right: parent.right
                wrapMode: Text.WordWrap
                text: Apps.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                id: separator

                anchors.top: reason.bottom
                anchors.topMargin: 12
                anchors.left: parent.left
                anchors.right: parent.right
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            Item {
                id: viewport

                anchors.top: separator.bottom
                anchors.topMargin: 12
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: searchBar.top
                anchors.bottomMargin: 12
                clip: true

                // The original launcher application list. It is instantiated
                // only with the catalog opt-in, and appsOnly keeps every
                // non-application state out of this bounded host.
                Loader {
                    id: listLoader

                    anchors.fill: parent
                    active: Apps.enabled && root.screenStateObject !== null
                    sourceComponent: Component {
                        AppList {
                            objectName: "launcherAppList"
                            width: parent ? parent.width : 0
                            height: parent ? parent.height : 0
                            search: searchBar
                            screenState: root.screenStateObject
                            appsOnly: true
                        }
                    }
                }

                // Same empty-state layout as the original launcher ContentList.
                Row {
                    id: emptyState

                    readonly property bool shown: root.listCount === 0

                    visible: shown
                    opacity: shown ? 1 : 0
                    scale: shown ? 1 : 0.5
                    spacing: Tokens.spacing.medium
                    padding: Tokens.padding.large
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter

                    MaterialIcon {
                        text: Apps.status === "ready" ? "manage_search" : root.statusIcon()
                        color: Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.extraLarge
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(120, Math.min(320, viewport.width - 120))

                        StyledText {
                            text: root.emptyTitle()
                            color: Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.body.builders.large.weight(Font.Medium).build()
                            width: parent.width
                            wrapMode: Text.WordWrap
                        }

                        StyledText {
                            text: root.emptyDescription()
                            color: Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.body.medium
                            width: parent.width
                            wrapMode: Text.WordWrap
                        }
                    }

                    Behavior on opacity {
                        Anim {
                            type: Anim.DefaultEffects
                        }
                    }

                    Behavior on scale {
                        Anim {}
                    }
                }
            }

            SearchBar {
                id: searchBar

                objectName: "launcherSearch"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                topPadding: Math.round((Tokens.padding.medium + Tokens.padding.large) / 2)
                bottomPadding: Math.round((Tokens.padding.medium + Tokens.padding.large) / 2)
                placeholderText: "Search applications"

                onAccepted: {
                    const current = listLoader.item?.currentItem;
                    if (root.smoke || !Apps.launchEnabled || !current || !current.modelData)
                        return;
                    Apps.launch(current.modelData);
                }
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
            return JSON.stringify(root.appsState());
        }
        // The bounded host's own query state; this is not synthesized OS
        // pointer/keyboard input and never launches an application.
        function search(text: string): string {
            searchBar.text = text;
            return JSON.stringify({query: text, count: Apps.search(text).length});
        }
        function quit(): void { Qt.quit(); }
    }

    Component.onCompleted: {
        if (!root.selectedScreen) {
            Qt.callLater(() => Qt.exit(1));
            return;
        }
        root.screenStateObject = root.screenStateComponent.createObject(root, {
            modelData: root.selectedScreen,
            launcher: true
        });
        if (!root.smoke)
            searchBar.forceActiveFocus();
    }

    Timer {
        id: check
        property int step
        running: root.smoke && root.selectedScreen !== null && root.screenStateObject !== null
        repeat: true
        interval: 800
        onTriggered: {
            if (root.failed)
                return;
            // Wait for the asynchronous native AppsFolder scan to finish.
            if (Apps.enabled && Apps.status === "scanning")
                return;
            const state = root.appsState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialState === null)
                    return;
            } else if (step === 1) {
                root.applySmokeQuery();
            } else if (step === 2) {
                root.checkSearchState(state);
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 3) {
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_APPS_CAPTURE", path);
                    console.log("CAELESTIA_APPS_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_APPS_FAIL: screenshot");
                    Qt.exit(1);
                });
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 20000
        onTriggered: {
            console.error("CAELESTIA_APPS_FAIL: timeout", Apps.status, Apps.reason);
            Qt.exit(1);
        }
    }
}
