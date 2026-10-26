// Native config smoke: only Observe and off, no desktop window or enable.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

ShellRoot {
    id: root
    settings.watchFiles: false

    property int step: 0
    property FileView config: FileView {
        path: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/shell.json"
        blockLoading: true
    }

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
    }

    Timer {
        interval: 600
        running: true
        repeat: true
        onTriggered: {
            try {
                root.check(!Tiling.backendEnabled, "native tiling must stay disabled");
                if (root.step === 0) {
                    root.check(Tiling.mode === "observe", "profile enables Observe without env");
                    root.check(Tiling.gapsIn === 10 && Tiling.gapsOut === 10, "initial profile gaps");
                    root.check(Tiling.includedPatterns.length === 1, "profile inclusion array");
                    root.check(Tiling.excludedPatterns.length === 2, "float and monitor rules");
                    root.config.setText(JSON.stringify({windows: {tiling: {
                        enabled: true, mode: "observe", gapsIn: 12, gapsOut: 14,
                        include: ["class:FixtureClass"], float: ["title:Dialog*"],
                        monitors: {"FixtureScreen": false}
                    }}}));
                } else if (root.step === 1) {
                    root.check(Tiling.mode === "observe", "reload stays Observe");
                    root.check(Tiling.gapsIn === 12 && Tiling.gapsOut === 14, "watched profile gaps");
                    root.check(Tiling.includedPatterns[0] === "class:FixtureClass", "watched inclusion");
                    root.check(Tiling.excludedPatterns.length === 2, "watched float/monitor rules");
                    root.config.setText(JSON.stringify({windows: {tiling: {enabled: false}}}));
                } else {
                    root.check(Tiling.mode === "off" && !Tiling.backendLoaded, "watched disable unloads backend");
                    console.log("CAELESTIA_TILING_CONFIG_SMOKE_PASS");
                    Qt.quit();
                }
                root.step++;
            } catch (error) {
                console.error("CAELESTIA_TILING_CONFIG_SMOKE_FAIL " + error.message);
                Qt.exit(1);
            }
        }
    }
}
