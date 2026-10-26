pragma Singleton

import ".."
import QtQuick
import Quickshell
import Caelestia.Config
import qs.services
import qs.utils

// Windows adaptation of the upstream scheme searcher. Schemes come from the
// profile-local caelestia package (the same scheme data `caelestia scheme list`
// serves); selecting a row calls the scheme bridge instead of spawning a CLI.
Searcher {
    id: root

    readonly property string currentScheme: SchemeGenerator.available ? SchemeGenerator.currentLabel : "Fixed Windows palette"
    readonly property string currentVariant: SchemeGenerator.available ? SchemeGenerator.currentVariant : "Unavailable"

    function transformSearch(search: string): string {
        return search.slice(`${GlobalConfig.launcher.actionPrefix}scheme `.length);
    }

    function selector(item: var): string {
        return `${item.name} ${item.flavour}`;
    }

    function reload(): void {
        syncRows();
        SchemeGenerator.refresh();
    }

    // Populate from whatever the bridge already returned. The list may finish
    // before this singleton is first referenced (for example when the launcher
    // opens), so do not depend only on the change signal.
    function syncRows(): void {
        const flat = [];
        const data = SchemeGenerator.schemes ?? ({});
        for (const name of Object.keys(data))
            for (const flavour of Object.keys(data[name]))
                flat.push({
                    name: name,
                    flavour: flavour,
                    colours: data[name][flavour]
                });
        schemes.model = flat.sort((a, b) => String(a.name + a.flavour).localeCompare(String(b.name + b.flavour)));
    }

    list: schemes.instances
    useFuzzy: GlobalConfig.launcher.useFuzzy.schemes
    keys: ["name", "flavour"]
    weights: [0.9, 0.1]

    Variants {
        id: schemes

        model: []

        Scheme {}
    }

    Connections {
        target: SchemeGenerator

        function onSchemeListChanged(): void {
            root.syncRows();
        }
    }

    Component.onCompleted: reload()

    component Scheme: QtObject {
        required property var modelData
        readonly property string name: modelData.name
        readonly property string flavour: modelData.flavour
        readonly property var colours: modelData.colours

        function onClicked(list: AppList): void {
            list.screenState.launcher = false;
            SchemeGenerator.setScheme(name, flavour, Wallpapers.actualCurrent);
        }
    }
}
