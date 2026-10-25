import QtQuick

// QML replacement for the excluded Caelestia.Models/AppDb frequency store.
//
// Upstream Apps.qml writes `${Paths.state}/apps.sqlite` through SQLite. This
// object keeps the same observable contract the launcher needs (a per-entry
// launch count and `incrementFrequency`) without SQLite, HOME/XDG paths or a
// database service. Persistence is delegated to an injected storage object so
// this file stays importable without Quickshell:
//
//   storage: {
//       available: bool,       // false keeps the store in memory only
//       text: string,          // file content, empty when missing
//       write(text): bool      // persist the new document
//   }
//
// FileAppFrequencyStore.qml supplies the real profile-local, atomic file
// storage. A corrupt or missing document is tolerated: the store starts empty,
// reports `corrupt`, and the next increment replaces the document with valid
// JSON. Invalid ids/counts are dropped rather than exposed as frequencies.
QtObject {
    id: root

    property var storage: null
    property string path: ""
    property var frequencies: ({})
    property bool loaded: false
    property bool corrupt: false
    property string lastError: ""
    // Confirmed writes. Asynchronous storage (`storage.asynchronous`) only
    // counts a write once it reports completion through writeFinished().
    property int writes: 0
    property int writesPending: 0
    property string savedText: ""

    // Persistence requires an explicit storage object that reports itself
    // available. There is no fallback path.
    readonly property bool persistent: storage !== null && storage.available === true
    readonly property int trackedCount: Object.keys(frequencies).length

    Component.onCompleted: root.load()

    function load(): void {
        root.corrupt = false;
        root.lastError = "";
        root.frequencies = {};

        if (!root.persistent) {
            root.loaded = true;
            return;
        }

        const text = typeof storage.text === "string" ? storage.text : "";
        if (text.trim().length === 0) {
            root.loaded = true;
            return;
        }

        let document = null;
        try {
            document = JSON.parse(text);
        } catch (error) {
            root.corrupt = true;
            root.lastError = "Ignoring a corrupt app frequency file: " + error.message;
            root.loaded = true;
            return;
        }

        if (!document || typeof document !== "object" || Array.isArray(document)
                || !document.frequencies || typeof document.frequencies !== "object"
                || Array.isArray(document.frequencies)) {
            root.corrupt = true;
            root.lastError = "Ignoring an app frequency file without a frequencies object.";
            root.loaded = true;
            return;
        }

        const clean = {};
        for (const id of Object.keys(document.frequencies)) {
            const value = document.frequencies[id];
            if (id.length === 0 || typeof value !== "number" || !isFinite(value) || value < 0)
                continue;
            const count = Math.floor(value);
            if (count > 0)
                clean[id] = count;
        }
        root.frequencies = clean;
        root.loaded = true;
    }

    function frequencyFor(id): int {
        if (typeof id !== "string" || id.length === 0)
            return 0;
        const value = root.frequencies[id];
        return typeof value === "number" && isFinite(value) && value > 0 ? Math.floor(value) : 0;
    }

    // Upstream increments the frequency before handing the entry to the
    // native launcher. This object performs the same state update, then writes
    // the new document atomically through its storage.
    function increment(id): int {
        if (typeof id !== "string" || id.length === 0) {
            root.lastError = "Cannot record a launch without a desktop entry id.";
            return 0;
        }
        const next = Object.assign({}, root.frequencies);
        next[id] = root.frequencyFor(id) + 1;
        root.frequencies = next;
        root.save();
        return next[id];
    }

    function toDocument(): string {
        return JSON.stringify({
            version: 1,
            frequencies: root.frequencies
        });
    }

    function save(): bool {
        root.savedText = root.toDocument();
        root.lastError = "";
        if (!root.persistent) {
            root.lastError = "App frequency history is memory-only; no profile state directory is configured.";
            return false;
        }
        const written = storage.write(root.savedText);
        if (written === false) {
            root.lastError = "The app frequency file could not be written.";
            return false;
        }
        if (storage.asynchronous === true)
            root.writesPending++;
        else
            root.writes++;
        return true;
    }

    function writeFinished(ok, message): void {
        root.writesPending = Math.max(0, root.writesPending - 1);
        if (ok === true) {
            root.writes++;
            return;
        }
        root.lastError = "The app frequency file could not be written"
            + (typeof message === "string" && message.length > 0 ? ": " + message : ".");
    }

    function reset(): void {
        root.frequencies = {};
        root.corrupt = false;
        root.lastError = "";
        root.save();
    }
}
