import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Services
import qs.services
import "BatteryLogic.js" as Logic

Scope {
    id: root

    property bool active: Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property var warnLevels: Logic.sortedLevels(GlobalConfig.general.battery.warnLevels.values)
    property var notified: ({})
    // -1 until the first successful power-source read, then 0 for AC and 1
    // for battery. Unknown readings never rewrite this state, so a transient
    // native failure cannot look like an AC transition.
    property int powerSource: -1

    function handleBatteryWarnings(): void {
        if (!root.active || !WindowsBattery.ready || !WindowsBattery.onBatteryKnown
            || !WindowsBattery.onBattery || !WindowsBattery.percentageKnown)
            return;
        const result = Logic.warnings(root.notified, WindowsBattery.percentage * 100,
            root.warnLevels, GlobalConfig.general.battery.criticalLevel);
        root.notified = result.notified;
        const level = result.warning;
        if (result.critical) {
            Toaster.toast(Tr.tr("Critical battery level"), Tr.tr("Plug in the charger now."),
                "battery_android_alert", Toast.Error);
        } else if (level) {
            Toaster.toast(level.title ? Tr.trMarked(level.title) : Tr.tr("Battery warning"),
                level.message ? Tr.trMarked(level.message) : Tr.tr("Battery level is low"),
                level.icon || "battery_android_alert", level.critical ? Toast.Error : Toast.Warning);
        }
    }

    Component.onCompleted: {
        Qt.callLater(root.updateReading);
    }

    function updateReading(): void {
        if (!root.active || !WindowsBattery.ready || !WindowsBattery.onBatteryKnown)
            return;
        const transition = Logic.powerTransition(root.powerSource, true, WindowsBattery.onBattery);
        root.powerSource = transition.source;
        if (transition.event === "unplugged") {
            if (GlobalConfig.utilities.toasts.chargingChanged)
                Toaster.toast(Tr.tr("Charger unplugged"), Tr.tr("Battery is discharging"), "power_off");
        } else if (transition.event === "plugged") {
            if (GlobalConfig.utilities.toasts.chargingChanged)
                Toaster.toast(Tr.tr("Charger plugged in"), Tr.tr("Connected to AC power"), "power");
            root.notified = {};
        }
        root.handleBatteryWarnings();
    }

    Connections {
        target: WindowsBattery
        function onReadyChanged(): void { Qt.callLater(root.updateReading); }
        function onPercentageKnownChanged(): void { Qt.callLater(root.updateReading); }
        function onPercentageChanged(): void { Qt.callLater(root.updateReading); }
        function onOnBatteryChanged(): void { Qt.callLater(root.updateReading); }
        function onOnBatteryKnownChanged(): void { Qt.callLater(root.updateReading); }
    }
}
