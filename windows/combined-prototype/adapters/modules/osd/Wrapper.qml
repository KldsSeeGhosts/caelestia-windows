pragma ComponentBehavior: Bound

import QtQuick
import qs.services

// Keep upstream motion and all audio feedback. Brightness bookkeeping still
// updates the slider, but only an actual level change opens the Windows OSD.
OsdWrapper {
    id: root

    brightnessOsdOnChange: false

    Connections {
        target: Brightness

        function onBrightnessFeedback(screenName: string, value: real): void {
            if (root.monitor?.screenName !== screenName)
                return;
            root.brightness = value;
            root.show();
        }
    }
}
