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

    function handleBatteryWarnings(): void {
        if (!root.active || !WindowsBattery.ready || !WindowsBattery.percentageKnown)
            return;
        if (!WindowsBattery.onBattery) {
            root.notified = {};
            return;
        }
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

    Component.onCompleted: root.handleBatteryWarnings()

    Connections {
        target: WindowsBattery
        function onReadyChanged(): void { root.handleBatteryWarnings(); }
        function onPercentageKnownChanged(): void { root.handleBatteryWarnings(); }
        function onPercentageChanged(): void { root.handleBatteryWarnings(); }
        function onOnBatteryChanged(): void {
            if (!root.active || !WindowsBattery.ready)
                return;
            if (WindowsBattery.onBattery) {
                if (GlobalConfig.utilities.toasts.chargingChanged)
                    Toaster.toast(Tr.tr("Charger unplugged"), Tr.tr("Battery is discharging"), "power_off");
                root.handleBatteryWarnings();
            } else {
                if (GlobalConfig.utilities.toasts.chargingChanged)
                    Toaster.toast(Tr.tr("Charger plugged in"), Tr.tr("Battery is charging"), "power");
                root.notified = {};
            }
        }
    }
}
