import QtQuick
import Quickshell
import Caelestia.Config

ShellRoot {
    Timer {
        interval: 0
        running: true
        onTriggered: {
            const disabled = [
                "CAELESTIA_COMBINED_LIVE", "CAELESTIA_WINDOWS_HYPR",
                "CAELESTIA_WINDOWS_HYPR_DISPATCH", "CAELESTIA_WINDOWS_AUDIO_CONTROLS",
                "CAELESTIA_WINDOWS_APP_LAUNCH", "CAELESTIA_WINDOWS_TRAY_ACTIVATION"
            ];
            if (disabled.some(name => Quickshell.env(name) === "1")
                    || Quickshell.env("QS_WINDOWS_TRAY_HOOK") !== "0"
                    || ["interactive", "observe"].includes(Quickshell.env("CAELESTIA_WINDOWS_TILING"))
                    || Quickshell.env("QT_QPA_PLATFORM") !== "offscreen"
                    || !Quickshell.env("CAELESTIA_PROFILE_ROOT")
                    || !Quickshell.env("CAELESTIA_CONFIG_DIR").startsWith(Quickshell.env("CAELESTIA_PROFILE_ROOT"))) {
                console.error("CAELESTIA_RUNNING_APPS_ENV_FAIL");
                Qt.exit(1);
                return;
            }
            console.log("CAELESTIA_RUNNING_APPS_ENV_PASS");
            Qt.quit();
        }
    }
}
