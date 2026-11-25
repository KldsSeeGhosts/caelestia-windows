pragma Singleton

import ".."
import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Services
import qs.services
import qs.utils
import qs.modules.nexus
import "../../../windows/services/apps/ShellActionSchema.js" as ShellActionSchema

Searcher {
    id: root

    function transformSearch(search: string): string {
        return search.slice(GlobalConfig.launcher.actionPrefix.length);
    }

    list: variants.instances
    useFuzzy: GlobalConfig.launcher.useFuzzy.actions

    function isDangerous(action): bool {
        return action.dangerous || action.verb === "runas"
            || ["shutdown", "reboot", "hibernate", "firmware", "logout"].includes(SessionManager.resolveCommand(action.command));
    }

    Variants {
        id: variants

        model: {
            const enableDangerous = GlobalConfig.launcher.enableDangerousActions;
            return GlobalConfig.launcher.actions.values.filter(action => action.enabled
                && (enableDangerous || !root.isDangerous(action)));
        }

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
        readonly property bool hasShellAction: ShellActionSchema.hasShellAction(modelData)

        function refuseShellAction(message: string): void {
            Toaster.toast(Tr.tr("Launcher action unavailable"), message, modelData.icon ?? "help_outline", Toast.Warning);
        }

        function runShellAction(list: AppList): void {
            const validated = ShellActionSchema.validateShellAction(modelData);
            if (!validated.ok) {
                refuseShellAction(validated.error);
                return;
            }
            if (typeof Native.AppActions.launchShellAction !== "function") {
                refuseShellAction(Tr.tr("This Windows shell backend cannot run configured launcher actions yet."));
                return;
            }
            let accepted = false;
            try {
                accepted = Native.AppActions.launchShellAction(validated.action) === true;
            } catch (error) {
                accepted = false;
            }
            if (!accepted) {
                refuseShellAction(Tr.tr("Windows refused the configured launcher action."));
                return;
            }
            list.screenState.launcher = false;
        }

        function onClicked(list: AppList): void {
            if (!enabled || (!GlobalConfig.launcher.enableDangerousActions && root.isDangerous(modelData)))
                return;
            if (hasShellAction) {
                runShellAction(list);
                return;
            }
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
            } else if (command[0] === "screenshotHistory") {
                list.screenState.launcher = false;
                CaptureUi.showHistory();
            } else if (command[0] === "record") {
                CaptureUi.record();
            } else if ((command[0] === "setMode" || command[0] === "generateMode") && command.length > 1) {
                list.screenState.launcher = false;
                Colours.setMode(command[1]);
            } else {
                list.screenState.launcher = false;
                SessionManager.exec(command);
            }
        }
    }
}
