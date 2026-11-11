pragma Singleton

import ".."
import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Services
import qs.services
import qs.utils
import qs.modules.nexus

Searcher {
    id: root

    function transformSearch(search: string): string {
        return search.slice(GlobalConfig.launcher.actionPrefix.length);
    }

    list: variants.instances
    useFuzzy: GlobalConfig.launcher.useFuzzy.actions

    Variants {
        id: variants

        model: [
            {name: "Calculator", description: "Arithmetic and functions", icon: "calculate", command: ["autocomplete", "calc"]},
            {name: "Settings", description: "Open Caelestia settings (Nexus)", icon: "settings", command: ["settings"]},
            {name: "Screenshot", description: "Glazier", icon: "screenshot_region", command: ["screenshot"]},
            {name: "Record screen", description: "Glazier", icon: "screen_record", command: ["record"]},
            {name: "Wallpaper", description: "Browse wallpaper folder", icon: "wallpaper", command: ["autocomplete", "wallpaper"]},
            {name: "Choose wallpaper file", description: "Open Windows image picker (Live controls)", icon: "image", command: ["chooseWallpaper"]},
            {name: "Schemes", description: "Choose a colour scheme and generate its palette", icon: "palette", command: ["autocomplete", "scheme"]},
            {name: "Variants", description: "Choose the Material You scheme variant", icon: "colors", command: ["autocomplete", "variant"]},
            {name: "Light mode", description: "Regenerate the palette in light mode", icon: "light_mode", command: ["generateMode", "light"]},
            {name: "Dark mode", description: "Regenerate the palette in dark mode", icon: "dark_mode", command: ["generateMode", "dark"]},
            {name: "Lock", description: "Lock Windows (Live controls)", icon: "lock", command: ["lock"]},
            {name: "Sleep", description: "Suspend Windows (Live controls)", icon: "bedtime", command: ["suspend"]}
        ]

        Action {}
    }

    component Action: QtObject {
        required property var modelData
        readonly property string name: modelData.name ? Tr.trMarked(modelData.name) : Tr.trCtx("Unnamed", "launcher action with no name")
        readonly property string desc: modelData.description ? Tr.trMarked(modelData.description) : Tr.trCtx("No description", "launcher action with no description")
        readonly property string icon: modelData.icon ?? "help_outline"
        readonly property list<string> command: modelData.command ?? []
        readonly property bool enabled: modelData.enabled ?? true
        readonly property bool dangerous: modelData.dangerous ?? false

        function onClicked(list: AppList): void {
            if (command.length === 0)
                return;

            if (command[0] === "autocomplete" && command.length > 1) {
                list.search.text = `${GlobalConfig.launcher.actionPrefix}${command[1]} `;
            } else if (command[0] === "settings") {
                WindowFactory.create();
                // Transfer foreground before closing the launcher can return
                // it to the previously focused application.
                list.screenState.launcher = false;
            } else if (command[0] === "chooseWallpaper") {
                Wallpapers.choose(Wallpapers.defaultPickerTarget(list.QsWindow.window?.screen));
            } else if (command[0] === "screenshot") {
                CaptureUi.screenshot("open");
            } else if (command[0] === "record") {
                CaptureUi.record();
            } else if ((command[0] === "setMode" || command[0] === "generateMode") && command.length > 1) {
                list.screenState.launcher = false;
                Colours.setMode(command[1]);
            } else {
                list.screenState.launcher = false;
                // Windows adaptation: the Windows SessionManager consumes every
                // command (including unknown ones) and sets allowDetachedFallback
                // false, so this can never launch an arbitrary process. Upstream
                // native SessionManager lacks the property, preserving the
                // original Linux fallback when exec() declines a command.
                if (!SessionManager.exec(command) && SessionManager.allowDetachedFallback !== false)
                    Quickshell.execDetached(command);
            }
        }
    }
}
