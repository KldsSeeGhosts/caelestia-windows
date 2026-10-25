//@ pragma AppId org.caelestia.windows-shell-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.Services
import Caelestia.Windows
import qs.components
import qs.services
import qs.modules.drawers

// Original native drawer window, bounded inside one screen. No AppBar, tiling,
// desktop hosting, taskbar changes, autostart, or session actions are enabled.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int initialScreenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    property int screenIndex: initialScreenIndex
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property bool monitorCycle: Quickshell.env("CAELESTIA_SHELL_MONITOR_CYCLE") === "1"
    readonly property int inset: 80
    readonly property int previewWidth: Math.min(900, (selectedScreen?.width ?? 1060) - inset * 2)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - inset * 2)

    settings.watchFiles: false

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

    WindowsFocusGuard {
        id: focusGuard
        target: win.contentItem
        active: !root.smoke && (win.screenState?.session ?? false)
        onOutcome: status => console.log("CAELESTIA_SHELL_FOCUS", status)
        onDismissRequested: win.screenState.session = false
    }

    ContentWindow {
        id: win

        screen: root.selectedScreen
        visible: root.selectedScreen !== null
        interactionEnabled: !root.smoke
        anchors.right: false
        anchors.bottom: false
        implicitWidth: root.previewWidth
        implicitHeight: root.previewHeight
        margins.left: root.inset
        margins.top: root.inset

        StyledText {
            x: 130
            y: 80
            width: Math.max(200, root.previewWidth - 300)
            wrapMode: Text.WordWrap
            text: "Caelestia Windows compatibility preview\n\nOriginal bar, session drawer, masks, shaders, and motion.\nHover the left edge to reveal the bar. Its power button opens the session drawer; Escape or an outside click dismisses it.\n\nSession actions are unavailable in this isolated profile."
            color: Colours.palette.m3onSurfaceVariant
        }
    }

    IpcHandler {
        target: "prototype"
        function state(): string {
            const panels = ShellState.componentsFor(win.screen)?.panels;
            const content = panels?.session.children.find(c => c.item)?.item;
            const power = CUtils.findChild(win.contentItem, "taskbarPowerButton");
            const center = item => {
                if (!item)
                    return null;
                const p = item.mapToItem(win.contentItem, item.width / 2, item.height / 2);
                return { x: p.x, y: p.y };
            };
            return JSON.stringify({
                screen: win.screen?.name, x: win.screen?.x, y: win.screen?.y,
                dpr: win.devicePixelRatio, width: win.width, height: win.height,
                barWidth: win.bar.implicitWidth, barHovered: win.bar.isHovered,
                barPinned: win.screenState?.bar,
                containsMouse: win.interactionWrapper.containsMouse,
                mouseX: win.interactionWrapper.mouseX, mouseY: win.interactionWrapper.mouseY,
                pressed: win.interactionWrapper.pressed,
                session: win.screenState?.session, sessionVisible: panels?.session.visible,
                sessionOffset: panels?.session.offsetScale,
                sessionFocusedIcon: content?.children.find(c => c.activeFocus)?.icon ?? "",
                powerCenter: center(power),
                sessionButtons: content?.children.filter(c => c.icon).map(c => ({
                    icon: c.icon, center: center(c), focused: c.activeFocus
                })) ?? [],
                sessionDragY: panels ? panels.sessionWrapper.y + win.borderThickness + panels.sessionWrapper.height / 2 : 0,
                barDragThreshold: win.contentItem.Config.bar.dragThreshold,
                sessionDragThreshold: win.contentItem.Config.session.dragThreshold,
                sessionVimKeybinds: win.contentItem.Config.session.vimKeybinds,
                launcher: win.screenState?.launcher, focusStatus: focusGuard.status
            });
        }
        function capture(): void {
            CUtils.saveItem(win.contentItem, Qt.resolvedUrl(Quickshell.env("CAELESTIA_SHELL_SCREENSHOT")));
        }
        function quit(): void { Qt.quit(); }
        function moveToScreen(index: int): bool {
            if (index < 0 || index >= Quickshell.screens.length)
                return false;
            root.screenIndex = index;
            return true;
        }
    }

    Connections {
        target: win.interactionWrapper
        enabled: Quickshell.env("CAELESTIA_SHELL_TRACE_INPUT") === "1"
        function onContainsMouseChanged(): void {
            console.log("CAELESTIA_SHELL_POINTER", win.interactionWrapper.containsMouse,
                win.interactionWrapper.mouseX, win.interactionWrapper.mouseY);
        }
    }

    Component.onCompleted: {
        if (!selectedScreen || (monitorCycle && Quickshell.screens.length < 2)) {
            console.error("CAELESTIA_SHELL_FAIL: requested screen does not exist", screenIndex);
            // Quickshell attaches the engine exit handler after creation.
            Qt.callLater(() => Qt.exit(1));
        }
    }

    Timer {
        id: check
        property int step
        property int cycle

        running: root.smoke && root.selectedScreen !== null
                 && (!root.monitorCycle || Quickshell.screens.length >= 2)
        repeat: true
        interval: 1200
        onTriggered: {
            const panels = ShellState.componentsFor(win.screen)?.panels;
            if (!panels || !win.screenState) {
                console.error("CAELESTIA_SHELL_FAIL: missing original component graph");
                Qt.exit(1);
                return;
            }
            if (step === 0) {
                console.log("CAELESTIA_SHELL_SCREEN", JSON.stringify({
                    index: root.screenIndex, name: win.screen.name,
                    x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio
                }));
                console.log("CAELESTIA_SHELL_GEOMETRY", win.screen.name,
                    win.screen.x, win.screen.y, win.width, win.height,
                    win.devicePixelRatio, win.contentItem.GraphicsInfo.api);
                const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
                if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                        || win.width !== root.previewWidth || win.height !== root.previewHeight
                        || bodyFont.status !== FontLoader.Ready
                        || iconFont.status !== FontLoader.Ready
                        || clockFont.status !== FontLoader.Ready
                        || SessionManager.available
                        || !SessionManager.exec(["caelestia-m1-unavailable-probe"])) {
                    console.error("CAELESTIA_SHELL_FAIL: geometry, fonts, DPI, or unavailable action boundary");
                    Qt.exit(1);
                    return;
                }
                win.bar.isHovered = true;
                win.screenState.session = true;
            } else if (step === 1) {
                const barContent = CUtils.findChild(win.contentItem, "taskbarClock");
                const power = CUtils.findChild(win.contentItem, "taskbarPowerButton");
                if (!barContent || !power || win.bar.implicitWidth < win.bar.contentWidth - 1
                        || panels.session.offsetScale > 0.01
                        || panels.session.width <= 0 || panels.session.height <= 0) {
                    console.error("CAELESTIA_SHELL_FAIL: original bar or session did not open");
                    Qt.exit(1);
                    return;
                }
                console.log("CAELESTIA_SHELL_OPEN", barContent.width, barContent.height,
                    panels.session.width, panels.session.height);
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                const capturePath = cycle === 0 ? path : path.replace(/\.png$/, "-screen" + root.screenIndex + ".png");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(capturePath), () => {
                    console.log("CAELESTIA_SHELL_CAPTURE", capturePath);
                    win.screenState.session = false;
                    win.bar.isHovered = false;
                }, () => {
                    console.error("CAELESTIA_SHELL_FAIL: screenshot");
                    Qt.exit(1);
                });
            } else if (step === 2) {
                if (panels.session.visible || panels.session.offsetScale < 0.99
                        || win.bar.implicitWidth > win.contentItem.Config.border.thickness + 1) {
                    console.error("CAELESTIA_SHELL_FAIL: original close animation");
                    Qt.exit(1);
                    return;
                }
                if (root.monitorCycle && cycle < 2) {
                    root.screenIndex = cycle === 0
                        ? (root.initialScreenIndex + 1) % Quickshell.screens.length
                        : root.initialScreenIndex;
                    cycle++;
                    step = -1;
                } else {
                    console.log("CAELESTIA_SHELL_PASS", CUtils.qtVersion);
                    Qt.quit();
                }
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: root.monitorCycle ? 30000 : 15000
        onTriggered: {
            console.error("CAELESTIA_SHELL_FAIL: timeout");
            Qt.exit(1);
        }
    }
}
