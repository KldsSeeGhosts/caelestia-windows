import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Services
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/ServicesPage.qml.
//
// Every polling, unit and scheme control is upstream and writes the same
// GlobalConfig keys the installed shell reads. Two Linux-only pieces are
// replaced:
//   * `Lyrics.preferredBackend` comes from the upstream Caelestia.Services
//     module, which the portable Windows build excludes (windows/README.md), so
//     the lyrics-backend select becomes an honest "unavailable" row;
//   * the page keeps the default-player select, because the staged Players
//     facade is backed by GSMTC and reports real identities.
PageBase {
    id: root

    // GPU types, ordered to match config::GpuType (Auto, Nvidia, Generic, None)
    readonly property list<MenuItem> gpuItems: [
        MenuItem {
            text: Tr.trCtx("Auto", "gpu type")
        },
        MenuItem {
            text: "NVIDIA"
        },
        MenuItem {
            text: Tr.trCtx("Generic", "gpu type")
        },
        MenuItem {
            text: Tr.trCtx("None", "gpu type")
        }
    ]

    title: Tr.tr("Services")

    readonly property bool agentUsageOn: GlobalConfig.windows?.quota?.enabled ?? true
    readonly property bool cpaHubOn: GlobalConfig.windows?.quota?.cpaHub ?? false

    readonly property string engineStatus: {
        if (!WallpaperEngine.enabled)
            return Tr.tr("Off");
        if (!WallpaperEngine.python)
            return Tr.tr("Unavailable");
        if (!WallpaperEngine.detected)
            return Tr.tr("Not installed");
        if (!WallpaperEngine.running)
            return Tr.tr("Installed, not running");
        return Tr.tr("Running");
    }
    readonly property string engineUnavailableHint: {
        if (WallpaperEngine.desktopControlError)
            return WallpaperEngine.desktopControlError;
        if (WallpaperEngine.desktopControlPending)
            return Tr.tr("Updating Wallpaper Engine desktop playback");
        if (!WallpaperEngine.python)
            return Tr.tr("The settings bridge is unavailable; Wallpaper Engine playback cannot be changed.");
        if (!WallpaperEngine.enabled)
            return Tr.tr("Caelestia shows its own wallpaper. Turning this off stops Wallpaper Engine wallpapers without quitting Wallpaper Engine.");
        if (!WallpaperEngine.detected)
            return Tr.tr("Install Wallpaper Engine to use it; Caelestia keeps its own wallpaper.");
        if (!WallpaperEngine.running)
            return Tr.tr("Start Wallpaper Engine to use it; Caelestia keeps its own wallpaper.");
        // Acknowledged handback: the process still runs, but the desktop is
        // the shell's again. Saying otherwise here contradicted what is shown.
        if (WallpaperEngine.desktopHandedBack)
            return Tr.tr("Wallpaper Engine handed the desktop back; Caelestia shows its own wallpaper while the process keeps running.");
        return Tr.tr("Wallpaper Engine is running and has not handed the desktop back; its wallpaper covers the desktop until it does.");
    }

    // Same allowlisted command and autostart choice as the session drawer.
    // The action is shown while unavailable so its reason is visible.
    readonly property var switchBackAction: SessionManager.sessionActionGating === true
        && SessionManager.sessionAction ? SessionManager.sessionAction(["switch-back"]) : null
    readonly property bool switchBackAvailable: switchBackAction !== null
        && switchBackAction.dispatchable === true
    readonly property string switchBackReason: switchBackAction !== null
        ? String(switchBackAction.reason ?? "") : ""
    readonly property bool switchBackPending: SessionManager.switchBackPending === true
    readonly property string switchBackError: String(SessionManager.switchBackError ?? "")

    function switchBack(): void {
        if (!root.switchBackAvailable)
            return;
        SessionManager.exec(["switch-back"]);
    }

    // GlobalConfig.windows is one QVariantMap, not a sub-object: copy it and
    // write it back whole, as the window management page does.
    function setQuota(key: string, on: bool): void {
        const windows = JSON.parse(JSON.stringify(GlobalConfig.windows ?? {}));
        const quota = Object.assign({}, windows.quota ?? {});
        quota[key] = on;
        windows.quota = quota;
        GlobalConfig.windows = windows;
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Detected running players, used as default-player options
        Variants {
            id: playerVariants

            model: [...new Set(Players.list.map(p => Players.getIdentity(p)).filter(id => id))]

            MenuItem {
                required property string modelData

                text: modelData
                icon: modelData === GlobalConfig.services.defaultPlayer ? "check" : ""
                activeIcon: "music_note"
            }
        }

        // Notifications
        SectionHeader {
            first: true
            text: Tr.tr("Notifications")
        }

        NavRow {
            first: true
            last: true
            icon: "notifications"
            text: Tr.tr("Notifications")
            subtext: Tr.tr("Notifications, toasts, timeouts")
            onClicked: root.nState.openSubPage(1)
        }

        // Windows session
        SectionHeader {
            text: Tr.tr("Windows session")
        }

        RowButton {
            objectName: "switchBackButton"
            first: true
            icon: "desktop_windows"
            text: Tr.tr("Switch back to Windows")
            subtext: !root.switchBackAvailable
                ? root.switchBackReason
                : root.switchBackPending
                    ? Tr.tr("Waiting for Caelestia to quit")
                    : Tr.tr("Quit Caelestia and restore the Windows taskbar and desktop")
            disabled: !root.switchBackAvailable
            onClicked: root.switchBack()
        }

        ToggleRow {
            objectName: "switchBackAutostartToggle"
            last: root.switchBackError === ""
            text: Tr.tr("Turn off autostart when switching back")
            subtext: Tr.tr("Removes Caelestia's Windows sign-in entry")
            checked: SessionManager.switchBackDisableAutostart
            onToggled: SessionManager.switchBackDisableAutostart = checked
            disabled: !root.switchBackAvailable
        }

        StyledText {
            objectName: "switchBackError"

            visible: root.switchBackError !== ""
            text: root.switchBackError
            color: Colours.palette.m3error
            font: Tokens.font.label.small
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        // Glazier ships with the shell. These rows state the chords the shell
        // owns; there is no separate-install setting.
        SectionHeader {
            text: Tr.tr("Glazier")
        }

        InfoRow {
            first: true
            icon: "screenshot_region"
            label: Tr.tr("Screenshot")
            subtext: Tr.tr("PrintScreen or Win+Shift+S")
            value: Glazier.available ? Tr.trCtx("Available", "Glazier state") : Tr.trCtx("Unavailable", "Glazier state")
        }

        InfoRow {
            last: true
            icon: "screen_record"
            label: Tr.tr("Recording")
            subtext: Tr.tr("Win+Shift+R")
            value: Recorder.available ? Tr.trCtx("Available", "Glazier state") : Tr.trCtx("Unavailable", "Glazier state")
        }

        // The agent usage drawer. Off removes the drawer and its hover strip and
        // stops every CPA request, live. The key is windows.quota.enabled.
        SectionHeader {
            text: Tr.tr("Agent usage")
        }

        ToggleRow {
            objectName: "agentUsageToggle"
            first: true
            text: Tr.tr("Agent usage panel")
            subtext: Tr.tr("Top-right drawer with AI quota. Also needs a CPA config")
            checked: root.agentUsageOn
            onToggled: root.setQuota("enabled", checked)
        }

        // windows.quota.cpaHub: read each CLIProxyAPI login through the hub for
        // token history, Top Models and Limit Resets. Stock CLIProxyAPI, which
        // has no quota summary, always uses this path.
        ToggleRow {
            objectName: "cpaHubToggle"
            last: true
            enabled: root.agentUsageOn
            text: Tr.tr("Detailed usage via CLIProxyAPI")
            subtext: Tr.tr("Adds token history, top models and limit resets. Needs Python")
            checked: root.cpaHubOn
            onToggled: root.setQuota("cpaHub", checked)
        }

        // Polling
        SectionHeader {
            text: Tr.tr("Polling")
        }

        StepperRow {
            first: true
            label: Tr.tr("Media refresh")
            // TRANSLATORS: ms is the millisecond unit, leave it untranslated
            subtext: Tr.tr("How often the media position updates (ms)")
            value: GlobalConfig.dashboard.mediaUpdateInterval
            from: 100
            to: 2000
            stepSize: 50
            onMoved: v => GlobalConfig.dashboard.mediaUpdateInterval = v
        }

        StepperRow {
            label: Tr.tr("System stats refresh")
            // TRANSLATORS: CPU and GPU are hardware abbreviations, leave them untranslated
            subtext: Tr.tr("CPU, memory and GPU update interval (seconds)")
            value: GlobalConfig.dashboard.resourceUpdateInterval / 1000
            from: 0.5
            to: 10
            stepSize: 0.5
            onMoved: v => GlobalConfig.dashboard.resourceUpdateInterval = Math.round(v * 1000)
        }

        StepperRow {
            last: true
            label: Tr.tr("Wi-Fi rescan")
            subtext: Tr.tr("How often available networks are rescanned (seconds)")
            value: GlobalConfig.nexus.networkRescanInterval / 1000
            from: 5
            to: 120
            stepSize: 5
            onMoved: v => GlobalConfig.nexus.networkRescanInterval = Math.round(v * 1000)
        }

        // Media & lyrics
        SectionHeader {
            text: Tr.tr("Media & lyrics")
        }

        // Upstream selects the synced-lyrics source here. The Windows build has
        // no lyrics service (no Local/LRCLIB/NetEase backend is compiled or
        // staged), so the row states that instead of offering a dead choice.
        InfoRow {
            first: true
            label: Tr.tr("Lyrics backend")
            subtext: Tr.trCtx("Unavailable", "lyrics service state")
            value: ""
        }

        SelectRow {
            last: true
            label: Tr.tr("Default player")
            subtext: Tr.tr("Preferred media player when several are open")
            menuItems: playerVariants.instances
            active: menuItems.find(i => i.text === GlobalConfig.services.defaultPlayer) ?? null
            fallbackIcon: "music_note"
            fallbackText: GlobalConfig.services.defaultPlayer || Tr.trCtx("Auto", "default media player")
            onSelected: item => GlobalConfig.services.defaultPlayer = item.text
        }

        // Input increments
        SectionHeader {
            text: Tr.tr("Input increments")
        }

        StepperRow {
            first: true
            label: Tr.tr("Volume step")
            subtext: Tr.tr("Amount the volume changes per scroll (%)")
            value: Math.round(GlobalConfig.services.audioIncrement * 100)
            from: 1
            to: 50
            stepSize: 1
            onMoved: v => GlobalConfig.services.audioIncrement = v / 100
        }

        StepperRow {
            label: Tr.tr("Brightness step")
            subtext: Tr.tr("Amount the brightness changes per scroll (%)")
            value: Math.round(GlobalConfig.services.brightnessIncrement * 100)
            from: 1
            to: 50
            stepSize: 1
            onMoved: v => GlobalConfig.services.brightnessIncrement = v / 100
        }

        StepperRow {
            last: true
            label: Tr.tr("Max volume")
            subtext: Tr.tr("Upper limit for output volume (%)")
            value: Math.round(GlobalConfig.services.maxVolume * 100)
            from: 50
            to: 200
            stepSize: 5
            onMoved: v => GlobalConfig.services.maxVolume = v / 100
        }

        // Service tuning
        SectionHeader {
            text: Tr.tr("Service tuning")
        }

        StepperRow {
            first: true
            // TRANSLATORS: bars of a spectrum analyser, not the taskbar
            label: Tr.tr("Visualiser bars")
            subtext: Tr.tr("Number of bars in the audio visualisers")
            value: GlobalConfig.services.visualiserBars
            from: 10
            to: 120
            stepSize: 2
            onMoved: v => GlobalConfig.services.visualiserBars = v
        }

        ToggleRow {
            text: Tr.tr("Smart colour scheme")
            subtext: Tr.tr("Derive theme mode and variant from the wallpaper")
            checked: GlobalConfig.services.smartScheme
            onToggled: GlobalConfig.services.smartScheme = checked
        }

        SelectRow {
            last: true
            label: Tr.tr("GPU")
            subtext: Gpu.name ? Tr.tr("Monitoring: %1").arg(Gpu.name) : Tr.tr("Override for GPU type")
            menuOnTop: true
            menuItems: root.gpuItems
            active: root.gpuItems[GlobalConfig.services.gpuType]
            onSelected: item => GlobalConfig.services.gpuType = root.gpuItems.indexOf(item)
        }

        // Wallpaper Engine is an optional third-party integration, not part of
        // a fresh install. It is off until this toggle writes it; a saved value
        // from an older profile is left alone until the user changes it here.
        SectionHeader {
            text: Tr.tr("Wallpaper Engine")
        }

        ToggleRow {
            first: true
            text: Tr.tr("Wallpaper Engine wallpapers")
            subtext: Tr.tr("Needs Wallpaper Engine installed and running. Turning this on resumes its wallpapers on all displays")
            checked: WallpaperEngine.enabled
            onToggled: WallpaperEngine.setEnabled(checked)
        }

        InfoRow {
            label: Tr.tr("Status")
            subtext: root.engineUnavailableHint
            value: root.engineStatus
        }
    }
}
