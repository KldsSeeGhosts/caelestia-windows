// Light native smoke for the clipboard overlay: the display-row model and the
// windows.clipboard gate.
//
// This test never reads, clears or modifies clipboard history. The picker is
// never opened, refresh()/setActive(true) are never called, and no image
// preview is requested. Only a read-only IsHistoryEnabled check can run when
// the enabled facade constructs the native type.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.clipboard
import qs.services
import "modules/clipboard/ClipboardHistory.js" as ClipboardRows

ShellRoot {
    id: root

    settings.watchFiles: false

    property int step: 0

    // Loads the picker QML (its windows stay invisible because opened is
    // false) so parse and binding errors fail this smoke. interactionEnabled
    // false also keeps the shortcut and IPC from opening it.
    ClipboardOverlay {
        id: clipboardOverlay

        interactionEnabled: false
    }

    property FileView config: FileView {
        path: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/shell.json"
        blockLoading: true
    }

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
    }

    function rowIds(rows): string {
        return rows.map(row => row.itemId).join(",");
    }

    function checkModel(): void {
        // Search sees text past the bounded preview without truncating input.
        const original = "x".repeat(9000) + "\nneedle beyond preview";
        const large = ClipboardRows.displayRows([{ id: "a", kind: "text", text: original }],
            "needle beyond", 60);
        root.check(large.length === 1, "search past the preview limit");
        root.check(large[0].fullText.length <= 8192, "preview text is bounded");
        root.check(large[0].itemId === "a", "row keeps its item id");
        root.check(original.length === 9022, "input text is not mutated");

        // Filtered rows keep ids and honour the output limit.
        const entries = [
            { id: "a", kind: "text", text: "first" },
            { id: "b", kind: "text", text: "MATCH one" },
            { id: "c", kind: "text", text: "third" },
            { id: "d", kind: "text", text: "match two" }
        ];
        root.check(root.rowIds(ClipboardRows.displayRows(entries, "match", 60)) === "b,d",
            "filtered rows keep their ids");
        root.check(root.rowIds(ClipboardRows.displayRows(entries, "match", 1)) === "b",
            "row limit");
        root.check(ClipboardRows.displayRows(entries, "", 0).length === 0, "zero limit");

        // Image, file, URL, colour, code and other items keep their action data.
        const kinds = ClipboardRows.displayRows([
            { id: "img", kind: "image", imageUrl: "file:///C:/cache/a.png",
              timestampLabel: "Monday 10:00" },
            { id: "file", kind: "text", text: "file:///C:/tmp/a%20b.png" },
            { id: "url", kind: "text", text: "https://example.com" },
            { id: "colour", kind: "text", text: "#123456" },
            { id: "code", kind: "text", text: "const x = 42;" },
            { id: "other", kind: "other", formats: "Bitmap, Html" }
        ], "", 60);
        root.check(kinds.map(row => row.entryType).join(",")
            === "image,file,url,color,code,other", "entry classification");
        root.check(kinds[0].previewImage === "file:///C:/cache/a.png", "image preview URL");
        root.check(kinds[0].title === "Image from Monday 10:00", "image title");
        root.check(kinds[1].path === "/C:/tmp/a b.png", "decoded file reference");
        root.check(kinds[1].title === "a b.png", "file reference title");
        root.check(kinds[2].fullText === "https://example.com", "URL body");
        root.check(kinds[3].colorValue === "#123456", "colour value");
        root.check(kinds[5].previewText.indexOf("Bitmap") >= 0, "Windows item formats");
    }

    function checkEnabled(): void {
        root.check(ClipboardHistory.enabled, "windows.clipboard defaults to enabled");
        root.check(ClipboardHistory.available, "the native backend loads when enabled");
        root.check(ClipboardHistory.status === "initializing",
            "no history is read before the picker opens: " + ClipboardHistory.status);
        root.check(ClipboardHistory.items.length === 0, "no history items at start");
        root.check(ClipboardHistory.historyEnabled === false, "history flag is never refreshed");
        root.check(ClipboardHistory.lastError.length === 0, "no startup error");
    }

    // Drives the picker's own rebuild with synthetic entries. The items are
    // set on the facade, so the real Windows history is never read.
    function checkDisplayUpdate(): void {
        ClipboardHistory.items = [
            { id: "smoke-a", kind: "text", text: "first entry" },
            { id: "smoke-b", kind: "text", text: "https://example.com" },
            { id: "smoke-c", kind: "text", text: "#123456" }
        ];
        clipboardOverlay.rebuildDisplay();
        root.check(clipboardOverlay.display.count === 3, "display rows are built");
        root.check(clipboardOverlay.display.get(0).itemId === "smoke-a", "row keeps its id");
        root.check(clipboardOverlay.display.get(0).entryType === "text", "text row kind");
        root.check(clipboardOverlay.display.get(1).entryType === "url", "URL row kind");
        root.check(clipboardOverlay.display.get(2).isColor, "colour row flag");
        root.check(clipboardOverlay.selectedIndex === 0, "first row is selected");

        ClipboardHistory.items = [];
        clipboardOverlay.rebuildDisplay();
        root.check(clipboardOverlay.display.count === 0, "display clears with the history");
        root.check(clipboardOverlay.selectedIndex === -1, "an empty display clears the selection");
    }

    function checkDisabled(): void {
        root.check(!ClipboardHistory.enabled, "windows.clipboard.enabled=false is honoured");
        root.check(!ClipboardHistory.available, "a disabled feature constructs no native type");
        root.check(ClipboardHistory.status === "disabled", "disabled status");
        root.check(ClipboardHistory.items.length === 0, "no history items while disabled");
    }

    Timer {
        interval: 600
        running: true
        repeat: true

        onTriggered: {
            try {
                if (root.step === 0) {
                    root.checkModel();
                    root.checkEnabled();
                    root.checkDisplayUpdate();
                    root.config.setText(JSON.stringify({ windows: { clipboard: { enabled: false } } }));
                } else if (root.step === 1) {
                    root.checkDisabled();
                    root.config.setText(JSON.stringify({ windows: { clipboard: { enabled: true } } }));
                } else {
                    root.checkEnabled();
                    console.log("CAELESTIA_CLIPBOARD_SMOKE_PASS");
                    Qt.quit();
                }
                root.step++;
            } catch (error) {
                console.error("CAELESTIA_CLIPBOARD_SMOKE_FAIL " + error.message);
                Qt.exit(1);
            }
        }
    }
}
