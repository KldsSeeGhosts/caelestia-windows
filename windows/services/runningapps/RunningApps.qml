pragma Singleton

import QtQuick
import qs.services

// Share the already opted-in Hypr observation. Native control still requires
// its existing dispatch opt-in; offscreen/read-only smoke cannot act on apps.
RunningAppsModel {
    source: Hypr.toplevels.values
    actionsEnabled: Hypr.available && Hypr.dispatchEnabled
}
