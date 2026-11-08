import QtQuick
import Quickshell
import Quickshell.Windows as Native
import qs.services
import qs.modules.background

QtObject {
    property WindowsBackground subject: WindowsBackground {}
    property ShellScreen screen: ShellScreen {}
    property int assertions: 0
    function check(value, message): void {
        assertions++;
        if (!value) throw new Error(message);
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            Quickshell.environment = {CAELESTIA_WINDOWS_BACKGROUND: "1"};
            // This fixture covers an enabled integration on a legacy
            // backend; the fresh disabled default is covered elsewhere.
            WallpaperEngine.options = {enabled: true};
            Screens.screens = [screen];
            Native.DesktopLayer.active = true;
            check(!subject.underlaySupported && !subject.underlayActive, "legacy feature detection");
            check(subject.enabled && subject.screens.length === 1, "legacy own desktop mounts screens");
            WallpaperEngine.running = true;
            check(subject.externalActive, "legacy observes external owner");
            check(!subject.enabled && subject.screens.length === 0, "legacy yields to owner");
            check(!Native.DesktopLayer.enabled, "legacy reconcile disables host");
            check(!subject.checkReady(screen), "active legacy host cannot claim successful yield");
            Native.DesktopLayer.active = false;
            check(subject.checkReady(screen), "inactive legacy host yields safely");
            WallpaperEngine.running = false;
            check(Native.DesktopLayer.enabled, "stopped owner enables legacy host");
            check(subject.enabled, "legacy own desktop enabled again");
            Quickshell.environment = {CAELESTIA_WINDOWS_BACKGROUND: "0"};
            check(!Native.DesktopLayer.enabled && subject.screens.length === 0, "request off releases legacy host");
            console.log("CAELESTIA_BACKGROUND_LEGACY_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_BACKGROUND_LEGACY_FAIL " + error);
            Qt.exit(1);
        }
    }
}
