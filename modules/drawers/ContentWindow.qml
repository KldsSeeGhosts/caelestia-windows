pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Caelestia.Blobs
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services
import qs.modules.bar

StyledWindow {
    id: root

    readonly property alias bar: bar
    readonly property alias interactionWrapper: interactions
    readonly property alias focusWindow: drawerFocusWindow
    readonly property alias focusGrab: focusGrab
    // Automated rendering can exercise the original graph without taking input.
    property bool interactionEnabled: true

    // Windows: on hot-unplug a screen's state leaves the ShellState lookup
    // before this window is deleted, so keep a fallback for teardown.
    readonly property ScreenState teardownState: ScreenState {
        modelData: root.screen
    }
    readonly property ScreenState screenState: ShellState.forScreen(screen) ?? teardownState

    // The monitor-sized window stays permanently non-activating. Interactive
    // drawers move their loader into this companion so typing, IME and focus
    // return target a window that cannot trigger Wallpaper Engine's fullscreen
    // pause rule. Each surface uses a fixed band with at least 64 logical px
    // less width than the monitor, so animated card geometry never resizes it.
    StyledWindow {
        id: drawerFocusWindow

        readonly property bool launcherFocus: root.interactionEnabled
            && root.screenState.launcher && root.contentItem.Config.launcher.enabled
        readonly property bool sessionFocus: root.interactionEnabled
            && panels.session.usesFocusWindow
        readonly property bool popoutFocus: root.interactionEnabled
            && panels.popouts.usesFocusWindow
        readonly property string surface: launcherFocus ? "launcher"
            : sessionFocus ? "session" : popoutFocus ? "popouts" : ""
        readonly property Item target: surface === "launcher" ? panels.launcher
            : surface === "session" ? panels.sessionWrapper
            : surface === "popouts" ? panels.popoutsWrapper : null
        readonly property bool active: surface !== "" && target !== null
        readonly property int fullscreenWidthClearance: 64
        readonly property int nonFullscreenWidth: Math.max(1, Math.round(screen.width - fullscreenWidthClearance))
        readonly property int launcherBandWidth: nonFullscreenWidth
        readonly property int sessionBandWidth: Math.min(nonFullscreenWidth, 640)
        readonly property int popoutBandWidth: Math.min(nonFullscreenWidth, 640)
        readonly property int bandWidth: surface === "session" ? sessionBandWidth
            : surface === "popouts" ? popoutBandWidth : launcherBandWidth
        readonly property int bandX: surface === "session" ? Math.max(0, Math.round(screen.width - bandWidth))
            : surface === "launcher" ? Math.max(0, Math.round((screen.width - bandWidth) / 2)) : 0
        readonly property Item card: surface === "launcher" ? panels.launcher
            : surface === "session" ? panels.session
            : surface === "popouts" ? panels.popouts : null
        readonly property Item viewportSource: {
            if (!active)
                return null;
            if (surface === "popouts")
                return panels.popoutsWrapper;
            if (surface === "session")
                return panels.sessionWrapper.clip ? panels.sessionWrapper : panels.session;
            return panels.launcher;
        }
        readonly property bool viewportClips: surface === "session" ? panels.sessionWrapper.clip
            : surface === "popouts" ? panels.popoutsWrapper.clip : false
        readonly property real cardSceneX: {
            if (!card)
                return 0;
            if (surface === "session")
                return panels.x + panels.sessionWrapper.x + panels.session.x;
            if (surface === "popouts")
                return panels.x + panels.popoutsWrapper.x + panels.popouts.x;
            return panels.x + card.x;
        }
        readonly property real cardSceneY: {
            if (!card)
                return 0;
            if (surface === "session")
                return panels.y + panels.sessionWrapper.y + panels.session.y;
            if (surface === "popouts")
                return panels.y + panels.popoutsWrapper.y + panels.popouts.y;
            return panels.y + card.y;
        }
        readonly property real viewportSceneX: {
            if (!viewportSource)
                return 0;
            if (surface === "session")
                return viewportSource === panels.session ? cardSceneX : panels.x + panels.sessionWrapper.x;
            if (surface === "popouts")
                return panels.x + panels.popoutsWrapper.x;
            return cardSceneX;
        }
        readonly property real viewportSceneY: {
            if (!viewportSource)
                return 0;
            if (surface === "session")
                return viewportSource === panels.session ? cardSceneY : panels.y + panels.sessionWrapper.y;
            if (surface === "popouts")
                return panels.y + panels.popoutsWrapper.y;
            return cardSceneY;
        }
        readonly property real contentX: cardSceneX - margins.left
        readonly property real contentY: cardSceneY - margins.top
        readonly property real viewportX: viewportSceneX - margins.left
        readonly property real viewportY: viewportSceneY - margins.top
        readonly property real viewportWidth: viewportSource?.width ?? 0
        readonly property real viewportHeight: viewportSource?.height ?? 0
        readonly property var inputItem: {
            if (!active)
                return null;
            for (const child of focusContent.children) {
                if (child.objectName === "drawerFocusCard" && child.focusSurface === surface)
                    return child;
            }
            return null;
        }
        readonly property rect inputBounds: inputItem?.inputBounds ?? Qt.rect(0, 0, 0, 0)
        readonly property rect inputRegionBounds: inputItem?.inputRegionBounds ?? Qt.rect(0, 0, 0, 0)
        readonly property bool pointerHovered: {
            if (!active || !inputItem || !cardHover.hovered)
                return false;
            const bounds = inputBounds;
            const pos = cardHover.point.scenePosition;
            return bounds.width > 0 && bounds.height > 0
                && pos.x >= bounds.x && pos.x < bounds.x + bounds.width
                && pos.y >= bounds.y && pos.y < bounds.y + bounds.height;
        }

        readonly property alias contentHost: focusContent

        screen: root.screen
        name: "drawers-focus"
        visible: active
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: (launcherFocus || sessionFocus)
            ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        mask: focusInputRegion
        anchors.top: true
        anchors.left: true
        margins.left: bandX
        margins.top: 0
        implicitWidth: bandWidth
        implicitHeight: Math.max(1, Math.round(screen.height))

        Region {
            id: focusInputRegion

            x: drawerFocusWindow.inputRegionBounds.x
            y: drawerFocusWindow.inputRegionBounds.y
            width: drawerFocusWindow.inputRegionBounds.width
            height: drawerFocusWindow.inputRegionBounds.height
        }

        FocusScope {
            id: focusContent

            anchors.fill: parent
            focus: true

            Keys.onEscapePressed: {
                if (drawerFocusWindow.surface === "launcher")
                    root.screenState.launcher = false;
                else if (drawerFocusWindow.surface === "session")
                    root.screenState.session = false;
                else if (drawerFocusWindow.surface === "popouts")
                    panels.popouts.close();
            }

            HoverHandler {
                id: cardHover
            }
        }
    }

    // Windows: the facade also accepts an injected monitor-shaped backend.
    readonly property var monitor: Hypr.monitorFor(screen)
    readonly property bool hasSpecialWorkspace: (monitor?.lastIpcObject.specialWorkspace?.name.length ?? 0) > 0
    // Windows workspaces span monitors; Hyprland workspaces already belong to one.
    // Windows: the backend's fullscreen-occluder verdict (the one AppBar uses) also counts, because a fullscreen window hidden from the task list is not a toplevel.
    readonly property bool hasFullscreenOnNormalWs: (monitor?.lastIpcObject.fullscreenOccluder ?? false) || (monitor?.activeWorkspace?.toplevels.values.some(t => t.monitor === root.monitor && t.lastIpcObject.fullscreen > 1) ?? false)
    readonly property bool hasFullscreen: {
        if (hasSpecialWorkspace) {
            const specialName = monitor?.lastIpcObject.specialWorkspace?.name;
            if (!specialName)
                return false;
            const specialWs = Hypr.workspaces.values.find(ws => ws.name === specialName);
            return specialWs?.toplevels.values.some(t => t.monitor === root.monitor && t.lastIpcObject.fullscreen > 1) ?? false;
        }
        return hasFullscreenOnNormalWs;
    }
    // The native AppBar verdict lowers Top windows without hiding them.
    // Overlay windows still need a real frame before desktop takeover.
    readonly property bool takeoverOccluded: (monitor?.lastIpcObject.fullscreenOccluder ?? false)
        && WlrLayershell.layer === WlrLayer.Top

    property real fsTransitionProg: hasFullscreen ? 1 : 0
    readonly property real sdfBorderOffset: 2 * fsTransitionProg // SDFs joins are not exact, so offset by 2px to ensure nothing shows
    readonly property real borderThickness: contentItem.Config.border.thickness * (1 - fsTransitionProg)
    readonly property real borderRounding: contentItem.Config.border.rounding * (1 - fsTransitionProg)
    readonly property real shadowOpacity: 0.7 * (1 - fsTransitionProg)
    readonly property real borderLayoutThickness: hasFullscreen ? 0 : contentItem.Config.border.thickness

    property color surfaceColour: Colours.tPalette.m3surface

    readonly property int dragMaskPadding: {
        // Without compositor data, keep input confined to the visible border.
        if (!monitor || focusGrab.active || panels.popouts.isDetached)
            return 0;

        if (monitor?.lastIpcObject.specialWorkspace?.name || monitor?.activeWorkspace?.toplevels.values.length > 0)
            return 0;

        const thresholds = [];
        for (const panel of ["dashboard", "launcher", "session", "sidebar"])
            if (contentItem.Config[panel].enabled)
                thresholds.push(contentItem.Config[panel].dragThreshold);
        return Math.max(0, ...thresholds);
    }

    onHasFullscreenChanged: {
        screenState.launcher = false;
        screenState.session = false;
        screenState.dashboard = false;
        // Windows: the quota drawer follows the dashboard's close paths.
        screenState.quota = false;
        panels.popouts.close();
    }

    name: "drawers"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: (fsTransitionProg > 0 && contentItem.Config.general.showOverFullscreen) || (hasSpecialWorkspace && hasFullscreenOnNormalWs) ? WlrLayer.Overlay : WlrLayer.Top
    // The monitor-sized visual host must never become the foreground window.
    // Keyboard focus belongs to the card-sized drawerFocusWindow above.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: !interactionEnabled ? noInputRegion : hasFullscreen ? emptyRegion : regions

    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true

    Behavior on fsTransitionProg {
        Anim {}
    }

    Behavior on surfaceColour {
        CAnim {}
    }

    Region {
        id: noInputRegion
    }

    Region {
        id: emptyRegion

        x: panels.notifications.x + bar.implicitWidth
        y: panels.notifications.y + root.borderThickness
        width: panels.notifications.width
        height: panels.notifications.height

        Region {
            x: root.width - width
            y: panels.osdWrapper.y + root.borderThickness
            width: panels.osdWrapper.width * (1 - panels.osd.offsetScale) + root.borderThickness
            height: panels.osd.height
        }
    }

    Regions {
        id: regions

        bar: bar
        panels: panels
        win: root

        // Windows: shared-edge rectangles also supply the hover predicates.
        WindowsHoverRegions {
            id: windowsHover
            screen: root.screen
            screens: Quickshell.screens
            win: root
            panels: panels
            bar: bar
        }
    }

    HyprlandFocusGrab {
        id: focusGrab

        active: {
            if (!root.interactionEnabled)
                return false;
            const s = root.screenState;
            const conf = root.contentItem.Config;
            if ((s.launcher && conf.launcher.enabled) || (s.session && conf.session.enabled) || (s.sidebar && conf.sidebar.enabled))
                return true;
            if (!conf.dashboard.showOnHover && s.dashboard && conf.dashboard.enabled)
                return true;
            if (panels.popouts.currentName.startsWith("traymenu") && (panels.popouts.current as StackView)?.depth > 1)
                return true;
            return false;
        }
        // The companion is hidden for the sidebar, dashboard and nested tray
        // menus. Target the monitor-sized host in that case so the native grab
        // still starts; it remains WindowDoesNotAcceptFocus and WS_EX_NOACTIVATE.
        windows: drawerFocusWindow.active ? [drawerFocusWindow] : [root]
        onCleared: {
            root.screenState.launcher = false;
            root.screenState.session = false;
            root.screenState.sidebar = false;
            root.screenState.dashboard = false;
            // Windows: close the ported quota drawer with the other drawers.
            root.screenState.quota = false;
            panels.popouts.hasCurrent = false;
            bar.closeTray();
        }
    }

    StyledRect {
        anchors.fill: parent
        opacity: (root.screenState.session && Config.session.enabled) || panels.popouts.detachedMode !== "" ? 0.5 : 0
        color: Colours.palette.m3scrim

        Behavior on opacity {
            Anim {
                type: Anim.SlowEffects
            }
        }
    }

    Item {
        anchors.fill: parent
        opacity: root.surfaceColour.a
        // Fullscreen drops the shadow entirely; keeping the layer would hold a
        // full-screen FBO and the blur ping-pong textures for nothing.
        layer.enabled: root.shadowOpacity > 0
        layer.effect: MultiEffect {
            shadowEnabled: true
            blurMax: 15
            shadowColor: Qt.alpha(Colours.palette.m3shadow, Math.max(0, root.shadowOpacity))
        }

        BlobGroup {
            id: blobGroup

            color: root.surfaceColour
            smoothing: root.contentItem.Config.border.smoothing
        }

        BlobInvertedRect {
            anchors.fill: parent
            anchors.margins: -50 // Make border thicker to smooth out bulge from closed drawers
            group: blobGroup
            radius: root.borderRounding
            borderLeft: bar.implicitWidth - anchors.margins - root.sdfBorderOffset
            borderRight: root.borderThickness - anchors.margins - root.sdfBorderOffset
            borderTop: root.borderThickness - anchors.margins - root.sdfBorderOffset
            borderBottom: root.borderThickness - anchors.margins - root.sdfBorderOffset
        }

        PanelBg {
            id: dashBg

            panel: panels.dashboard
            deformAmount: 0.1
        }

        // Windows: the ported quota drawer gets its own blob surface.
        PanelBg {
            id: quotaBg

            panel: panels.quota
            deformAmount: 0.1
        }

        PanelBg {
            id: launcherBg

            panel: panels.launcher
            deformAmount: 0.1
        }

        PanelBg {
            id: sessionBg

            panel: panels.sessionWrapper
            deformAmount: 0.2
            x: panels.sessionWrapper.x + panels.session.x + bar.implicitWidth
            implicitWidth: panels.session.width
        }

        PanelBg {
            id: sidebarBg

            panel: panels.sidebar
            deformAmount: 0.03
            implicitHeight: panel.height * (1 / rawDeformMatrix.m22) + 2
            exclude: panels.sidebar.offsetScale > 0.08 ? [] : [utilsBg]
            bottomLeftRadius: Math.max(0, Math.min(1, panels.sidebar.offsetScale / 0.3)) * radius
        }

        PanelBg {
            id: osdBg

            panel: panels.osdWrapper
            deformAmount: 0.25
            x: panels.osdWrapper.x + panels.osd.x + bar.implicitWidth
            implicitWidth: panels.osd.width
        }

        PanelBg {
            id: notifsBg

            panel: panels.notifications
        }

        PanelBg {
            id: utilsBg

            panel: panels.utilities
            deformAmount: panels.sidebar.visible ? 0.1 : 0.15
            exclude: panels.sidebar.offsetScale > 0.08 ? [] : [sidebarBg]
            topLeftRadius: Math.max(0, Math.min(1, panels.sidebar.offsetScale / 0.3)) * radius
        }

        PanelBg {
            id: popoutBg

            // Extra width to prevent vertical movement deformation partially detaching panel from bar
            property real extraWidth: panels.popouts.isDetached ? 0 : 0.2

            panel: panels.popoutsWrapper
            deformAmount: panels.popouts.isDetached ? 0.05 : panels.popouts.hasCurrent ? 0.15 : 0.1
            x: panels.popoutsWrapper.x + panels.popouts.x + bar.implicitWidth - panels.popouts.width * extraWidth
            implicitWidth: panels.popouts.width * (1 + extraWidth)

            Behavior on extraWidth {
                Anim {}
            }
        }
    }

    Interactions {
        id: interactions

        enabled: root.interactionEnabled
        focusWindow: root.focusWindow
        screen: root.screen
        popouts: panels.popouts
        screenState: root.screenState
        panels: panels
        bar: bar
        borderThickness: root.borderLayoutThickness
        fullscreen: root.hasFullscreen
        // Windows: widen only the two hover triggers on shared edges.
        windowsHover: windowsHover

        Panels {
            id: panels

            focusWindow: root.focusWindow
            screen: root.screen
            screenState: root.screenState
            bar: bar
            borderThickness: root.borderThickness

            utilities.horizontalStretch: (sidebarBg.rawDeformMatrix.m11 - 1) / 2 + 1
            utilities.deformMatrix: utilsBg.rawDeformMatrix

            dashboard.transform: Matrix4x4 {
                matrix: dashBg.deformMatrix
            }
            // Windows: match the ported quota panel's blob deformation.
            quota.transform: Matrix4x4 {
                matrix: quotaBg.deformMatrix
            }
            launcher.focusTransformMatrix: launcherBg.deformMatrix
            launcher.transform: Matrix4x4 {
                matrix: launcherBg.deformMatrix
            }
            session.focusTransformMatrix: sessionBg.deformMatrix
            session.transform: Matrix4x4 {
                matrix: sessionBg.deformMatrix
            }
            sidebar.transform: Matrix4x4 {
                matrix: sidebarBg.deformMatrix
            }
            osd.transform: Matrix4x4 {
                matrix: osdBg.deformMatrix
            }
            notifications.transform: Matrix4x4 {
                matrix: notifsBg.deformMatrix
            }
            utilities.transform: Matrix4x4 {
                matrix: utilsBg.deformMatrix
            }
            popouts.focusTransformMatrix: popoutBg.deformMatrix
            popouts.transform: Matrix4x4 {
                matrix: popoutBg.deformMatrix
            }
        }

        BarWrapper {
            id: bar

            anchors.top: parent.top
            anchors.bottom: parent.bottom

            screen: root.screen
            screenState: root.screenState
            popouts: panels.popouts

            fullscreen: root.hasFullscreen
        }
    }

    ShellState.ComponentRef {
        screen: root.screen
        slot: "rootWindow"
        component: root
    }

    ShellState.ComponentRef {
        screen: root.screen
        slot: "interactionWrapper"
        component: interactions
    }

    ShellState.ComponentRef {
        screen: root.screen
        slot: "bar"
        component: bar
    }

    ShellState.ComponentRef {
        screen: root.screen
        slot: "panels"
        component: panels
    }

    component PanelBg: BlobRect {
        required property Item panel
        property real deformAmount: 0.15

        group: blobGroup
        x: panel.x + bar.implicitWidth
        y: panel.y + root.borderThickness
        implicitWidth: panel.width
        implicitHeight: panel.height
        radius: Tokens.rounding.extraLarge
        deformScale: (deformAmount * Config.appearance.deformScale) / 10000
    }
}
