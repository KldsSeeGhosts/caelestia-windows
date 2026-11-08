import QtQuick
import "EditorLogic.js" as Logic

// The editor's tool state and annotations for one capture. Picker.qml owns one
// and resets it at each capture. The toolbar, the canvas and the annotation
// layer all bind to it, and fixtures drive it directly, so no pointer input is
// needed to test the editor. The geometry and the undo rules live in
// EditorLogic.js.
//
// Stroke coordinates are logical pixels relative to the selection's top left
// corner.
Item {
    id: root

    visible: false

    // The tool, as an id from EditorLogic.TOOLS.
    property string tool: Logic.DEFAULT_TOOL
    property string color: Logic.DEFAULT_COLOR
    property real size: Logic.DEFAULT_SIZE
    // { strokes, redo }. Replaced on every change.
    property var history: Logic.emptyHistory()
    // The stroke being drawn, or null. Its points change in place, so `revision`
    // changes with them.
    property var draft: null
    property int revision
    // The colour and size popover is open.
    property bool inkOpen
    property bool clearArmed
    // The toolbar after the user dragged it, as { x, y }, or null for automatic.
    property var barPosition: null
    // The device pixel ratio, for skipping samples under half a physical pixel.
    property real scale: 1

    readonly property bool canUndo: Logic.canUndo(history)
    readonly property bool canRedo: Logic.canRedo(history)
    readonly property bool drawing: draft !== null
    readonly property var strokes: history.strokes

    function reset(): void {
        tool = Logic.DEFAULT_TOOL;
        color = Logic.DEFAULT_COLOR;
        size = Logic.DEFAULT_SIZE;
        history = Logic.emptyHistory();
        draft = null;
        inkOpen = false;
        clearArmed = false;
        barPosition = null;
    }

    function setTool(id: string): void {
        disarmClear();
        inkOpen = false;
        if (Logic.toolById(id))
            tool = id;
    }

    function setColor(index: int): void {
        if (index >= 0 && index < Logic.COLORS.length)
            color = Logic.COLORS[index];
    }

    function setSize(index: int): void {
        if (index >= 0 && index < Logic.SIZES.length)
            size = Logic.SIZES[index].size;
    }

    function toggleInk(): void {
        disarmClear();
        inkOpen = !inkOpen;
    }

    // A press on the canvas starts a stroke and closes the popover.
    function pressAt(x: real, y: real): void {
        inkOpen = false;
        disarmClear();
        draft = Logic.startDraft(tool, color, size, x, y);
        revision++;
    }

    function moveTo(x: real, y: real): void {
        if (!draft)
            return;
        const result = Logic.moveDraft(draft, x, y, scale);
        if (result.done)
            history = Logic.commit(history, result.done);
        if (result.changed)
            revision++;
    }

    function releaseAt(): void {
        if (!draft)
            return;
        const stroke = draft.stroke;
        draft = null;
        if (!Logic.isEmpty(stroke))
            history = Logic.commit(history, stroke);
        revision++;
    }

    // A stroke that is still being drawn is dropped, not committed.
    function abandon(): void {
        draft = null;
        revision++;
    }

    function undo(): void {
        if (draft)
            return;
        history = Logic.undo(history);
    }

    function redo(): void {
        if (draft)
            return;
        history = Logic.redo(history);
    }

    // The first press arms Clear, the second one clears. Returns whether it cleared.
    function pressClear(): bool {
        const result = Logic.clearPress(clearArmed);
        clearArmed = result.armed;
        if (result.clear) {
            history = Logic.clearAll();
            draft = null;
            revision++;
        }
        inkOpen = false;
        return result.clear;
    }

    function disarmClear(): void {
        clearArmed = false;
    }

    // Runs the keys that only change this state. Returns "handled" for those,
    // "copy" or "save" for the keys the owner must act on, and "" for a key the
    // editor ignores. A stroke being drawn ignores every key.
    function shortcut(key: int, ctrl: bool, shift: bool, alt: bool): string {
        const result = Logic.shortcut(key, ctrl, shift, alt);
        if (!result || draft)
            return "";
        if (result.action === "tool")
            setTool(result.tool);
        else if (result.action === "undo")
            undo();
        else if (result.action === "redo")
            redo();
        else
            return result.action;
        return "handled";
    }

    Timer {
        interval: Logic.CLEAR_ARM_MS
        running: root.clearArmed
        onTriggered: root.disarmClear()
    }
}
