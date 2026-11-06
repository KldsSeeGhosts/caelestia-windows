import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.Multimedia
import Caelestia.Shaders
import Caelestia.State
import qs.services

Item {
    id: root
    objectName: "desktopWallpaper"

    readonly property transitionShader shader: {
        CUtils.dependency(Config.background.wallpaperTransition);
        let transition = CUtils.enumToString(Config.background, "wallpaperTransition");
        if (!transition)
            return Shaders.crossfade;

        transition = transition[0].toLowerCase() + transition.slice(1);
        return Shaders[transition] ?? Shaders.crossfade;
    }

    // Windows keeps each background's image with its owning display.
    property string source: Qt.platform.os === "windows" && typeof Wallpapers.currentForScreen === "function"
        ? Wallpapers.currentForScreen(root.QsWindow.window?.screen) : Wallpapers.current
    property ShaderEffectSource currentCapture: capture1
    property real transitionProgress: 1
    // the Windows shell keeps Wallpaper Engine's process alive after the
    // engine closes its wallpaper. On that handback the source changes while
    // the background window may still have no frame of its own; the capture
    // below then holds a black frame, or its scheduled update never completes
    // while the window is covered, and live keeps the dead engine preview.
    // Apply the handback file directly and keep the shader out of the way. A
    // capture scheduled before the handback must not cover it later, so every
    // schedule carries the serial of the source change that asked for it.
    // Read the handback state directly: the source change can arrive in the
    // same notification that sets it, before a QML binding would update.
    function engineHandedBack(): bool {
        return Qt.platform.os === "windows" && typeof WallpaperEngine !== "undefined"
            && WallpaperEngine.desktopHandedBack;
    }
    property int captureSerial: 0

    function applyHandback(): void {
        transitionAnim.stop();
        ++captureSerial;
        capture1.visible = false;
        capture2.visible = false;
        transition.from = null;
        transitionProgress = 1;
        live.source = source;
    }

    // Windows : the underlay retains its own source while covered.
    // Handback can interrupt a capture without another source change.
    Connections {
        target: Qt.platform.os === "windows" && typeof WallpaperEngine !== "undefined" ? WallpaperEngine : null
        function onDesktopHandedBackChanged(): void {
            if (root.engineHandedBack())
                root.applyHandback();
        }
    }

    onSourceChanged: {
        if (engineHandedBack()) {
            applyHandback();
            return;
        }
        transitionAnim.stop();
        const serial = ++captureSerial;

        // Always toggle capture so transition.from changes and re-acquires
        // live's texture provider after its layer was disabled while idle.
        currentCapture = currentCapture === capture1 ? capture2 : capture1;
        if (transitionProgress < 1) {
            currentCapture.sourceItem = transition;
        } else {
            currentCapture.sourceItem = live;
        }

        currentCapture.captureSerial = serial;
        currentCapture.visible = true;
        currentCapture.scheduleUpdate();
    }

    Component.onCompleted: live.source = source

    NumberAnimation on transitionProgress {
        id: transitionAnim

        running: false
        duration: root.shader.duration * Tokens.anim.durations.scale
        easing: root.shader.easing
        to: 1
    }

    ShaderEffectSource {
        id: capture1
        property int captureSerial: 0

        anchors.fill: parent
        live: false
        visible: false

        onScheduledUpdateCompleted: {
            visible = false;
            // A handback replaced this transition with the verified source
            // directly; an older capture must not set the progress back over
            // it.
            if (root.engineHandedBack() || captureSerial !== root.captureSerial)
                return;
            transition.from = this;
            root.transitionProgress = 0;
            live.source = root.source;
            if (live.ready)
                transitionAnim.start();
        }
    }

    ShaderEffectSource {
        id: capture2
        property int captureSerial: 0

        anchors.fill: parent
        live: false
        visible: false

        onScheduledUpdateCompleted: {
            visible = false;
            // See capture1: a capture scheduled before the handback is stale.
            if (root.engineHandedBack() || captureSerial !== root.captureSerial)
                return;
            transition.from = this;
            root.transitionProgress = 0;
            live.source = root.source;
            if (live.ready)
                transitionAnim.start();
        }
    }

    Visual {
        id: live

        anchors.fill: parent
        playing: PersistentState.wallpaperPlaying
        animate: false
        // Windows: retain the original texture-provider lifetime across
        // idle -> capture -> transition, rather than re-creating the
        // shader input during the handoff. Other platforms keep idle gating.
        layer.enabled: Qt.platform.os === "windows" || root.transitionProgress < 1

        onReadyChanged: {
            if (ready && source === root.source)
                transitionAnim.start();
        }
    }

    ShaderEffect {
        id: transition

        property Item from
        property Item to: live
        property real progress: root.transitionProgress

        anchors.fill: parent
        visible: root.transitionProgress < 1
        fragmentShader: root.shader.url
    }
}
