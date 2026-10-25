import QtQuick
import Quickshell.Services.UPower
import qs.components
import qs.services
import qs.utils

MaterialIcon {
    required property color colour

    // Windows host: the upstream power-profile icon reads PowerProfiles, whose
    // only Windows capability is an overlay-scheme write. Hosts that keep that
    // service out of the process set this false; the icon then reports the
    // unavailable battery status instead of substituting a profile state.
    property bool profileStatusEnabled: true

    animate: true
    text: {
        if (!UPower.displayDevice.isLaptopBattery) {
            if (!profileStatusEnabled)
                return "battery_alert";
            if (PowerProfiles.profile === PowerProfile.PowerSaver)
                return "energy_savings_leaf";
            if (PowerProfiles.profile === PowerProfile.Performance)
                return "rocket_launch";
            return "balance";
        }
        return Icons.getBatteryIcon(UPower.displayDevice.percentage, [UPowerDeviceState.Charging, UPowerDeviceState.FullyCharged, UPowerDeviceState.PendingCharge].includes(UPower.displayDevice.state));
    }
    color: !UPower.onBattery || UPower.displayDevice.percentage > 0.2 ? colour : Colours.palette.m3error
    fill: 1
}
