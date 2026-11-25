pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Windows
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.services
// The facade is staged next to the original launcher services, so this
// relative import resolves to windows/services/apps in both the repository and
// the staged prototype tree.
import "../../../windows/services/apps"
import "../../../windows/services/apps/ShellActionSchema.js" as ShellActionSchema

// Windows `Apps` singleton. Preserves the useful original
// modules/launcher/services/Apps.qml contract the launcher consumes:
// `search`/`query`, `list`, `keys`, `weights`, `useFuzzy`, `selector` and
// `launch` (plus the AppDb-shaped list items' fields).
//
// Both opt-ins are child-process environment variables:
//   CAELESTIA_WINDOWS_APPS=1       enumerate and search (read-only)
//   CAELESTIA_WINDOWS_APP_LAUNCH=1 additionally permit explicit launches
//
// Referencing this singleton while disabled never resolves DesktopEntries:
// the native facade lives behind an inactive Loader. Enumeration and search
// never launch; launch() also refuses every request without the separate
// launch opt-in. The frequency store is only created with the catalog opt-in.
AppsService {
    id: root

    enabled: Quickshell.env("CAELESTIA_WINDOWS_APPS") === "1"
    launchEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_APP_LAUNCH") === "1"

    catalog: nativeLoader.item ?? null
    catalogError: nativeLoader.status === Loader.Error
        ? "The Windows app catalog component failed to load." : ""
    frequencyStore: storeLoader.item ?? null

    favouriteApps: GlobalConfig.launcher.favouriteApps
    hiddenApps: GlobalConfig.launcher.hiddenApps
    specialPrefix: GlobalConfig.launcher.specialPrefix
    useFuzzy: GlobalConfig.launcher.useFuzzy.apps
    terminalCommand: GlobalConfig.general.apps.terminal
    terminalLauncher: root.launchTerminalEntry

    function launchWithFeedback(entry): bool {
        const started = launch(entry) === true;
        if (!started)
            Toaster.toast(Tr.tr("Could not start app"),
                lastLaunchError || Tr.tr("Windows could not start the application."),
                "error", Toast.Error);
        return started;
    }

    function launchTerminalEntry(entry, terminal): bool {
        root.terminalLauncherError = "";
        const validated = ShellActionSchema.terminalAction(terminal, entry);
        if (!validated.ok) {
            root.terminalLauncherError = validated.error;
            return false;
        }
        if (typeof AppActions.launchShellAction !== "function") {
            root.terminalLauncherError = "This Windows shell backend cannot run terminal applications yet.";
            return false;
        }
        try {
            if (AppActions.launchShellAction(validated.action) === true)
                return true;
        } catch (error) {
            root.terminalLauncherError = String(error);
            return false;
        }
        root.terminalLauncherError = "Windows refused the terminal application launch.";
        return false;
    }

    // Observable construction policy for host/smoke assertions.
    readonly property bool nativeRequested: nativeLoader.active
    readonly property bool storeRequested: storeLoader.active
    readonly property bool backendLoaded: nativeLoader.item !== null
    readonly property string stateDir: Quickshell.env("CAELESTIA_STATE_DIR") || ""

    readonly property Component _catalogComponent: Component {
        NativeAppCatalog {}
    }
    readonly property Component _storeComponent: Component {
        FileAppFrequencyStore {
            stateDir: root.stateDir
        }
    }

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        sourceComponent: root.enabled ? root._catalogComponent : null
    }

    readonly property Loader _storeLoader: Loader {
        id: storeLoader

        active: root.enabled
        sourceComponent: root.enabled ? root._storeComponent : null
    }
}
