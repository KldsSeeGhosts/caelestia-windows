import QtQuick
import Quickshell.Io
import "AppStoragePath.js" as StoragePath

// Profile-local file storage for AppFrequencyStore.
//
// The path is derived only from the isolated CAELESTIA_STATE_DIR supplied by
// the host (`stateDir`), never from HOME/XDG. FileView writes atomically
// through QSaveFile (rename over the previous document) and printErrors is off
// so a missing or unreadable file is a normal first-run state rather than a
// diagnostic. The file is never watched: frequencies are this process's state,
// and reloading mid-session could discard an unsaved increment.
AppFrequencyStore {
    id: root

    property string stateDir: ""

    readonly property string fileName: StoragePath.FILE_NAME
    readonly property string resolvedPath: StoragePath.frequenciesPath(stateDir)
    readonly property FileView fileView: FileView {
        id: view

        path: root.resolvedPath
        blockLoading: true
        atomicWrites: true
        watchChanges: false
        printErrors: false

        // setText() returns before the atomic write completes; only these
        // signals establish whether the document was persisted.
        onSaved: root.writeFinished(true, "")
        onSaveFailed: error => root.writeFinished(false, String(error))
    }

    // The store only ever sees this object. `available` mirrors path
    // confinement: without a valid isolated state directory the frequency
    // history stays in memory for the process lifetime.
    readonly property QtObject fileStorage: QtObject {
        readonly property bool available: root.resolvedPath !== ""
        readonly property bool asynchronous: true
        readonly property string text: root.resolvedPath !== "" ? view.text() : ""

        function write(text): bool {
            if (root.resolvedPath === "")
                return false;
            view.setText(text);
            return true;
        }
    }

    path: resolvedPath
    storage: fileStorage
}
