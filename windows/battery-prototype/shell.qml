//@ pragma AppId org.caelestia.windows-battery-prototype
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
import qs.modules.bar.popouts as BarPopouts
import qs.modules.bar.components.status as BarStatus

// A separate bounded M2 host for the original read-only battery status. Other
// services, profile selection, power-plan writes and all shell controllers
// stay unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(640, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - 160)
    property var initialBatteryState

    settings.watchFiles: false

    function batteryState(): var {
        return {
            status: Battery.status, reason: Battery.reason, enabled: Battery.enabled,
            backendLoaded: Battery.backend !== null,
            nativeReadAvailable: Battery.nativeReadAvailable,
            presenceKnown: Battery.presenceKnown,
            observationAvailable: Battery.observationAvailable,
            present: Battery.present, absent: Battery.absent,
            laptopBattery: Battery.laptopBattery,
            hasBattery: Battery.hasBattery, percentageKnown: Battery.percentageKnown,
            onBatteryKnown: Battery.onBatteryKnown, onBattery: Battery.onBattery,
            charging: Battery.charging, state: Battery.state,
            percentage: Battery.percentage, timeToEmpty: Battery.timeToEmpty,
            iconName: Battery.iconName,
            profilesEnabled: Battery.profilesEnabled,
            profileWritesRequested: Battery.profileWritesRequested,
            profileWritesEnabled: Battery.profiles.writesPermitted,
            profileStatusEnabled: Battery.profileStatusEnabled,
            profileControlsEnabled: Battery.profileControlsEnabled,
            profilesState: Battery.profiles.state,
            profileReason: Battery.profiles.reason,
            profile: Battery.profiles.profile,
            profileName: Battery.profiles.profileName,
            availableProfiles: Battery.profiles.availableProfiles,
            performanceMapped: Battery.profiles.performanceMapped,
            performanceClaim: Battery.profiles.performanceClaim,
            writeResultAvailable: Battery.profiles.writeResultAvailable,
            writeState: Battery.profiles.writeState,
            writeReason: Battery.profiles.writeReason,
            writeError: Battery.profiles.writeError,
            writeTimeoutMs: Battery.profiles.writeTimeoutMs
        };
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

        name: "battery-prototype"
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
                    text: "Caelestia Windows battery"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                // The original bar status icon. Instantiated only with the
                // read-only opt-in: it binds UPower directly, like upstream.
                Loader {
                    id: statusLoader
                    active: Battery.enabled
                    sourceComponent: BarStatus.BatteryStatus {
                        colour: Colours.palette.m3onSurfaceVariant
                        profileStatusEnabled: Battery.profileStatusEnabled
                        observationAvailable: Battery.observationAvailable
                        percentageKnown: Battery.percentageKnown
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    const parts = [Battery.reason];
                    if (Battery.profilesEnabled) {
                        parts.push(Battery.profiles.reason);
                        if (Battery.profiles.writeReason)
                            parts.push(Battery.profiles.writeReason);
                        parts.push(Battery.profileWritesRequested
                            ? "Power profile writes are enabled for explicit selections."
                            : "Power profiles are observed read-only; writes need the separate opt-in.");
                    } else if (Battery.enabled) {
                        parts.push("Read-only preview. Profile selection and power-plan writes stay unavailable.");
                    }
                    return parts.join("\n");
                }
                color: Colours.palette.m3onSurfaceVariant
            }

            Flickable {
                id: viewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: batteryHost.item ? batteryHost.item.implicitHeight : 0
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                // The original popout content. Instantiated only with the
                // read-only opt-in: it binds UPower directly, like upstream.
                Loader {
                    id: batteryHost
                    active: Battery.enabled
                    width: viewport.width
                    sourceComponent: BarPopouts.Battery {
                        id: batteryContent
                        objectName: "windowsBatteryPopout"
                        profileStatusEnabled: Battery.profileStatusEnabled
                        profileControlsEnabled: Battery.profileControlsEnabled
                        profileWritesEnabled: Battery.profiles.writesPermitted
                        availableProfiles: Battery.profiles.availableProfiles
                        selectProfile: profile => Battery.profiles.requestProfile(profile)
                        observationAvailable: Battery.observationAvailable
                        percentageKnown: Battery.percentageKnown
                        powerSourceKnown: Battery.onBatteryKnown
                        timeToFullSupported: false
                    }
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
            return JSON.stringify(root.batteryState());
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
            if (Battery.status === "initializing")
                return;
            const state = root.batteryState();
            if (step === 0) {
                const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
                const profilesExpected = Quickshell.env("CAELESTIA_WINDOWS_POWER_PROFILES") === "1";
                const writesExpected = Quickshell.env("CAELESTIA_WINDOWS_POWER_PROFILE_WRITES") === "1"
                    && !root.smoke;
                if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                        || win.width !== root.previewWidth || win.height !== root.previewHeight
                        || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                        || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_BATTERY") === "1")
                        || state.profilesEnabled !== profilesExpected
                        || state.profileWritesRequested !== writesExpected
                        || state.profileWritesEnabled !== false
                        || Battery.nativeProfilesRequested !== profilesExpected
                        || batteryHost.active !== Battery.enabled || statusLoader.active !== Battery.enabled) {
                    console.error("CAELESTIA_BATTERY_FAIL: UI, fonts, DPI or service policy");
                    Qt.exit(1);
                    return;
                }
                if (state.enabled && (batteryHost.item?.profileStatusEnabled !== state.profileStatusEnabled
                        || batteryHost.item?.profileControlsEnabled !== state.profileControlsEnabled
                        || batteryHost.item?.profileWritesEnabled !== state.profileWritesEnabled
                        || JSON.stringify(batteryHost.item?.availableProfiles ?? [])
                            !== JSON.stringify(state.availableProfiles)
                        || statusLoader.item?.profileStatusEnabled !== state.profileStatusEnabled
                        || batteryHost.item?.timeToFullSupported !== false
                        || batteryHost.item?.powerSourceKnown !== state.onBatteryKnown)) {
                    console.error("CAELESTIA_BATTERY_FAIL: profile or observation hooks are not wired to capability");
                    Qt.exit(1);
                    return;
                }
                root.initialBatteryState = state;
                console.log("CAELESTIA_BATTERY_SCREEN", JSON.stringify({
                    index: root.screenIndex, name: win.screen.name,
                    x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
                    width: win.width, height: win.height
                }));
                console.log("CAELESTIA_BATTERY_INITIAL", JSON.stringify(state));
            } else if (step === 1) {
                if (!Number.isFinite(state.percentage) || state.percentage < 0 || state.percentage > 1) {
                    console.error("CAELESTIA_BATTERY_FAIL: percentage guard");
                    Qt.exit(1);
                    return;
                }
                if (state.charging !== [Battery.stateCharging, Battery.stateFullyCharged, Battery.statePendingCharge].includes(state.state)) {
                    console.error("CAELESTIA_BATTERY_FAIL: charging gate");
                    Qt.exit(1);
                    return;
                }
                if (state.enabled) {
                    if (state.status !== "ready" && state.status !== "unavailable") {
                        console.error("CAELESTIA_BATTERY_FAIL: read-only status did not settle: " + state.status);
                        Qt.exit(1);
                        return;
                    }
                    if (state.observationAvailable !== (state.nativeReadAvailable && state.presenceKnown)
                            || state.absent !== (state.observationAvailable && !state.present)) {
                        console.error("CAELESTIA_BATTERY_FAIL: observation capability mismatch");
                        Qt.exit(1);
                        return;
                    }
                    if (state.hasBattery !== (state.present && state.laptopBattery)) {
                        console.error("CAELESTIA_BATTERY_FAIL: battery gating");
                        Qt.exit(1);
                        return;
                    }
                    if (state.profilesEnabled) {
                        if (state.profilesState !== "observing" && state.profilesState !== "unknown") {
                            console.error("CAELESTIA_BATTERY_FAIL: profile observation did not settle: "
                                + state.profilesState);
                            Qt.exit(1);
                            return;
                        }
                        const observing = state.profilesState === "observing";
                        if (state.profileStatusEnabled !== observing
                                || state.profileControlsEnabled !== observing) {
                            console.error("CAELESTIA_BATTERY_FAIL: profile host flags do not match capability");
                            Qt.exit(1);
                            return;
                        }
                        if (state.profileWritesEnabled !== false || state.profileWritesRequested !== false
                                || state.writeState !== "idle") {
                            console.error("CAELESTIA_BATTERY_FAIL: smoke permitted a profile write");
                            Qt.exit(1);
                            return;
                        }
                        if (batteryHost.item?.profileStatusEnabled !== state.profileStatusEnabled
                                || batteryHost.item?.profileControlsEnabled !== state.profileControlsEnabled
                                || batteryHost.item?.profileWritesEnabled !== false
                                || JSON.stringify(batteryHost.item?.availableProfiles ?? [])
                                    !== JSON.stringify(state.availableProfiles)) {
                            console.error("CAELESTIA_BATTERY_FAIL: original profile hooks are not read-only");
                            Qt.exit(1);
                            return;
                        }
                        if (observing) {
                            if (!state.availableProfiles.includes(state.profile)) {
                                console.error("CAELESTIA_BATTERY_FAIL: observed profile is not mapped");
                                Qt.exit(1);
                                return;
                            }
                        } else if (state.profile !== -1) {
                            console.error("CAELESTIA_BATTERY_FAIL: unknown profile was projected");
                            Qt.exit(1);
                            return;
                        }
                    } else if (state.profilesState !== "disabled" || Battery.nativeProfilesRequested
                            || state.profileStatusEnabled || state.profileControlsEnabled
                            || state.profileWritesEnabled || state.profile !== -1
                            || state.availableProfiles.length !== 0) {
                        console.error("CAELESTIA_BATTERY_FAIL: profile opt-in built the profile backend");
                        Qt.exit(1);
                        return;
                    }
                    if (!state.observationAvailable) {
                        // A failed or unknown native read proves neither presence
                        // nor absence. No projection may invent either outcome.
                        if (state.present || state.absent || state.hasBattery
                                || state.percentage !== 0 || state.percentageKnown
                                || state.timeToEmpty !== 0 || state.charging
                                || state.iconName !== "" || state.state !== Battery.stateUnknown) {
                            console.error("CAELESTIA_BATTERY_FAIL: unavailable read invented battery state");
                            Qt.exit(1);
                            return;
                        }
                    } else if (!state.present) {
                        // Truthful absence: no fake level, estimate, charging
                        // state or icon. Adapter constants mirror
                        // UPowerDeviceState; Charging/FullyCharged/PendingCharge
                        // are the upstream "charging" set.
                        if (state.percentage !== 0 || state.timeToEmpty !== 0
                                || state.percentageKnown || state.charging
                                || state.iconName !== "" || state.state !== Battery.stateUnknown) {
                            console.error("CAELESTIA_BATTERY_FAIL: absent battery invented state");
                            Qt.exit(1);
                            return;
                        }
                    } else if (!state.percentageKnown && state.percentage !== 0) {
                        console.error("CAELESTIA_BATTERY_FAIL: unknown percentage retained a stale value");
                        Qt.exit(1);
                        return;
                    }
                    if (state.absent && state.onBattery) {
                        console.error("CAELESTIA_BATTERY_FAIL: battery power without a battery");
                        Qt.exit(1);
                        return;
                    }
                    // The original status icon consults PowerProfiles only while
                    // a mapped profile is actually observed, and its glyph must
                    // state absence/unknown truthfully otherwise.
                    const icon = statusLoader.item?.text;
                    if (statusLoader.item?.profileStatusEnabled !== state.profileStatusEnabled) {
                        console.error("CAELESTIA_BATTERY_FAIL: status icon profile guard");
                        Qt.exit(1);
                        return;
                    }
                    let expectedIcon = null;
                    if (!state.observationAvailable)
                        expectedIcon = "battery_unknown";
                    else if (!state.hasBattery)
                        expectedIcon = state.profileStatusEnabled
                            ? (state.profile === Battery.profiles.profileSaver ? "energy_savings_leaf"
                                : state.profile === Battery.profiles.profilePerformance
                                    ? "rocket_launch" : "balance")
                            : "battery_alert";
                    else if (!state.percentageKnown)
                        expectedIcon = "battery_unknown";
                    if (expectedIcon !== null && icon !== expectedIcon) {
                        console.error("CAELESTIA_BATTERY_FAIL: status icon truthfulness: " + icon);
                        Qt.exit(1);
                        return;
                    }
                } else if (state.status !== "disabled" || state.backendLoaded
                        || batteryHost.item !== null || statusLoader.item !== null
                        || state.profilesState !== "disabled" || Battery.nativeProfilesRequested
                        || state.profileStatusEnabled || state.profileControlsEnabled
                        || state.profileWritesEnabled || state.profile !== -1
                        || state.availableProfiles.length !== 0) {
                    console.error("CAELESTIA_BATTERY_FAIL: disabled mode constructed the backend or original components");
                    Qt.exit(1);
                    return;
                }
            } else if (step === 2) {
                console.log("CAELESTIA_BATTERY_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_BATTERY_CAPTURE", path);
                    // Exercise the actual host hook after the stable snapshots
                    // and capture. Writes must be off, so this selection is
                    // refused by the service before any native submission.
                    // Use an invalid target as an additional safety boundary.
                    if (Battery.enabled) {
                        const attempts = Battery.profiles.writeAttempts;
                        const rejections = Battery.profiles.rejectedWrites;
                        if (Battery.profiles.writesEnabled !== false
                                || typeof batteryHost.item?.selectProfile !== "function"
                                || batteryHost.item.selectProfile(-1) !== false
                                || Battery.profiles.writeState !== "rejected"
                                || Battery.profiles.rejectedWrites !== rejections + 1
                                || Battery.profiles.writeAttempts !== attempts) {
                            console.error("CAELESTIA_BATTERY_FAIL: selector bypassed the read-only service");
                            Qt.exit(1);
                            return;
                        }
                        console.log("CAELESTIA_BATTERY_SELECTOR_PASS: read-only selection rejected before submission");
                    }
                    console.log("CAELESTIA_BATTERY_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_BATTERY_FAIL: screenshot");
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
            console.error("CAELESTIA_BATTERY_FAIL: timeout", Battery.status, Battery.reason);
            Qt.exit(1);
        }
    }
}
