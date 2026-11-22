pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Windows as Native
import Caelestia
import "../../utils/FileUrls.js" as FileUrls

Scope {
    id: root

    property bool enabled
    property string directory: (Quickshell.env("TMP") || Quickshell.env("TEMP") || "").replace(/\\/g, "/").replace(/\/+$/, "")
    // Use a longer startup grace than for drags this process owns: a
    // different installation or a drop target could still be using the file.
    property double maxAge: 24 * 60 * 60 * 1000
    property var dragRequests: ({})

    Timer {
        running: root.enabled && !!FileUrls.fromLocalPath(root.directory)
        interval: 2500
        onTriggered: scan.active = true
    }

    Loader {
        id: scan
        active: false
        sourceComponent: Item {
            FolderListModel {
                id: files
                folder: FileUrls.fromLocalPath(root.directory)
                showDirs: true
                showDotAndDotDot: false
                nameFilters: ["caelestia-clipboard-*.png", "caelestia-drag-*"]
                onStatusChanged: {
                    if (status !== FolderListModel.Ready)
                        return;
                    const cutoff = Date.now() - root.maxAge;
                    const requests = {};
                    for (let i = 0; i < count; i++) {
                        const name = get(i, "fileName");
                        const path = root.directory + "/" + name;
                        if (!(Number(get(i, "fileModified")) < cutoff))
                            continue;
                        if (!isFolder(i) && /^caelestia-clipboard-[a-f0-9]{32}\.png$/.test(name))
                            CUtils.removeCaptureTemp(path);
                        else if (isFolder(i) && /^caelestia-drag-[a-f0-9]{32}$/.test(name))
                            requests[Native.FsUtils.listDirAsync(path)] = path;
                    }
                    root.dragRequests = requests;
                    Qt.callLater(() => scan.active = false);
                }
            }
        }
    }

    Connections {
        target: Object.keys(root.dragRequests).length ? Native.FsUtils : null
        function onListDirFinished(request, path, entries): void {
            if (root.dragRequests[request] !== path)
                return;
            const next = Object.assign({}, root.dragRequests);
            delete next[request];
            root.dragRequests = next;
            if (entries.length === 1 && /^annotate-[\w ()-]+\.png$/.test(entries[0].name))
                CUtils.removeDragFile(path + "/" + entries[0].name);
        }
    }
}
