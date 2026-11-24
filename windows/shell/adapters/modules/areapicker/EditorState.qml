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
    property bool fill: false
    // { strokes, undo, redo }. Replaced on every change.
    property var history: Logic.emptyHistory()
    // The stroke being drawn, or null. Its points change in place, so `revision`
    // changes with them.
    property var draft: null
    // The selection move being dragged, or null.
    property var moving: null
    // The inline text edit in progress: { x, y, text }, or null.
    property var textEdit: null
    property int revision
    // The colour, size and fill popover is open.
    property bool inkOpen
    // The tool group whose flyout is open, or -1.
    property int toolMenu: -1
    property bool clearArmed
    // The selected annotation's stable id, or -1.
    property int selectedId: -1
    // The toolbar after the user dragged it, as { x, y }, or null for automatic.
    property var barPosition: null
    // The device pixel ratio, for skipping samples under half a physical pixel.
    property real scale: 1

    readonly property bool canUndo: Logic.canUndo(history)
    readonly property bool canRedo: Logic.canRedo(history)
    readonly property bool drawing: draft !== null
    readonly property bool textEditing: textEdit !== null
    readonly property var strokes: history.strokes
    readonly property int selectedIndex: Logic.indexOfId(strokes, selectedId)
    readonly property var selectedStroke: selectedIndex >= 0 ? strokes[selectedIndex] : null
    readonly property var selectionBounds: Logic.selectionBounds(selectedStroke)

    function reset(): void {
        tool = Logic.DEFAULT_TOOL;
        color = Logic.DEFAULT_COLOR;
        size = Logic.DEFAULT_SIZE;
        fill = false;
        history = Logic.emptyHistory();
        draft = null;
        moving = null;
        textEdit = null;
        inkOpen = false;
        toolMenu = -1;
        clearArmed = false;
        selectedId = -1;
        barPosition = null;
    }

    function restore(strokes: var, ratio: real): void {
        history = { strokes: Logic.scaleStrokes(strokes, ratio), undo: [[]], redo: [] };
        selectedId = -1;
    }

    function closePopovers(): void {
        inkOpen = false;
        toolMenu = -1;
    }

    function setTool(id: string): void {
        disarmClear();
        closePopovers();
        if (textEditing)
            commitText();
        if (Logic.toolById(id)) {
            tool = id;
            if (id !== "select")
                selectedId = -1;
        }
    }

    function selectedCopy(): var {
        return selectedStroke ? Logic.copyStroke(selectedStroke) : null;
    }

    function replaceSelected(stroke: var): void {
        if (selectedIndex >= 0)
            history = Logic.replaceStroke(history, selectedIndex, stroke);
    }

    function syncSelectionStyle(stroke: var): void {
        if (!stroke)
            return;
        color = stroke.color;
        size = stroke.size;
        fill = stroke.fill === true;
    }

    function setColor(index: int): void {
        if (index < 0 || index >= Logic.COLORS.length)
            return;
        color = Logic.COLORS[index];
        if (textEdit)
            textEdit = Object.assign({}, textEdit, { color: color });
        const stroke = selectedCopy();
        if (stroke && stroke.color !== color) {
            stroke.color = color;
            replaceSelected(stroke);
        }
    }

    function setSize(index: int): void {
        if (index < 0 || index >= Logic.SIZES.length)
            return;
        size = Logic.SIZES[index].size;
        if (textEdit)
            textEdit = Object.assign({}, textEdit, { size: size });
        const stroke = selectedCopy();
        if (stroke && stroke.size !== size) {
            stroke.size = size;
            replaceSelected(stroke);
        }
    }

    function setFill(value: bool): void {
        fill = value;
        const stroke = selectedCopy();
        if (stroke && (stroke.tool === "rect" || stroke.tool === "circle") && stroke.fill !== value) {
            stroke.fill = value;
            replaceSelected(stroke);
        }
    }

    function toggleFill(): void {
        if (selectedStroke && (selectedStroke.tool === "rect" || selectedStroke.tool === "circle"))
            setFill(!selectedStroke.fill);
        else
            setFill(!fill);
    }

    function toggleInk(): void {
        disarmClear();
        toolMenu = -1;
        inkOpen = !inkOpen;
    }

    function toggleToolMenu(group: int): void {
        disarmClear();
        inkOpen = false;
        toolMenu = toolMenu === group ? -1 : group;
    }

    // The select tool picks the topmost stroke at the point. A hit starts a
    // move preview; empty canvas only clears the selection.
    function selectPressAt(x: real, y: real): void {
        const index = Logic.hitTest(strokes, x, y);
        if (index < 0) {
            selectedId = -1;
            moving = null;
            return;
        }
        const stroke = strokes[index];
        selectedId = stroke.id;
        syncSelectionStyle(stroke);
        moving = {
            id: stroke.id, startX: x, startY: y,
            before: strokes.slice(), base: Logic.copyStroke(stroke), moved: false
        };
    }

    function beginText(x: real, y: real): void {
        selectedId = -1;
        textEdit = { x: x, y: y, text: "", color: color, size: size };
        revision++;
    }

    function updateText(text: string): void {
        if (textEdit)
            textEdit = Object.assign({}, textEdit, { text: text });
    }

    function commitText(): bool {
        if (!textEdit)
            return false;
        const edit = textEdit;
        textEdit = null;
        if (edit.text.length > 0)
            history = Logic.commit(history, Logic.textStroke(edit.color || color, edit.size || size, edit.x, edit.y, edit.text));
        revision++;
        return true;
    }

    function cancelText(): void {
        if (!textEdit)
            return;
        textEdit = null;
        revision++;
    }

    // A press on the canvas starts an annotation, selects one, places text or a
    // step, and closes the popovers.
    function pressAt(x: real, y: real): void {
        closePopovers();
        disarmClear();
        if (textEditing) {
            commitText();
            return;
        }
        if (tool === "select") {
            selectPressAt(x, y);
            return;
        }
        selectedId = -1;
        if (tool === "text") {
            beginText(x, y);
            return;
        }
        if (tool === "step") {
            history = Logic.commit(history, Logic.stepStroke(color, size, x, y));
            revision++;
            return;
        }
        draft = Logic.startDraft(tool, color, size, x, y, fill);
        revision++;
    }

    function moveSelectionTo(x: real, y: real): void {
        if (!moving)
            return;
        const index = Logic.indexOfId(strokes, moving.id);
        if (index < 0)
            return;
        const dx = x - moving.startX;
        const dy = y - moving.startY;
        if (!moving.moved && Math.hypot(dx, dy) < 1)
            return;
        const next = strokes.slice();
        next[index] = Logic.translateStroke(moving.base, dx, dy);
        history = Logic.replaceCurrent(history, next);
        moving.moved = true;
        revision++;
    }

    function moveTo(x: real, y: real, constrain: bool): void {
        if (moving) {
            moveSelectionTo(x, y);
            return;
        }
        if (!draft)
            return;
        const result = Logic.moveDraft(draft, x, y, scale, constrain === true);
        if (result.done)
            history = Logic.commit(history, result.done);
        if (result.changed)
            revision++;
    }

    function releaseAt(): void {
        if (moving) {
            const move = moving;
            moving = null;
            if (move.moved)
                history = Logic.changeStrokes(history, move.before, strokes);
            revision++;
            return;
        }
        if (!draft)
            return;
        const stroke = draft.stroke;
        draft = null;
        if (!Logic.isEmpty(stroke))
            history = Logic.commit(history, stroke);
        revision++;
    }

    // A stroke or move that is still being drawn is dropped, not committed.
    function abandon(): void {
        if (moving)
            history = Logic.replaceCurrent(history, moving.before);
        moving = null;
        draft = null;
        revision++;
    }

    function eraseAt(x: real, y: real): bool {
        if (textEditing)
            return false;
        const index = Logic.hitTest(strokes, x, y);
        if (index < 0)
            return false;
        if (strokes[index].id === selectedId)
            selectedId = -1;
        history = Logic.removeStroke(history, index);
        revision++;
        return true;
    }

    function deleteSelected(): bool {
        if (textEditing || selectedIndex < 0)
            return false;
        const index = selectedIndex;
        selectedId = -1;
        history = Logic.removeStroke(history, index);
        revision++;
        return true;
    }

    function syncSelection(): void {
        if (selectedId >= 0 && Logic.indexOfId(strokes, selectedId) < 0)
            selectedId = -1;
    }

    function undo(): void {
        if (draft || moving || textEditing)
            return;
        history = Logic.undo(history);
        syncSelection();
    }

    function redo(): void {
        if (draft || moving || textEditing)
            return;
        history = Logic.redo(history);
        syncSelection();
    }

    // The first press arms Clear, the second one clears. Returns whether it cleared.
    function pressClear(): bool {
        const result = Logic.clearPress(clearArmed);
        clearArmed = result.armed;
        if (result.clear) {
            history = Logic.clearAll();
            draft = null;
            moving = null;
            textEdit = null;
            selectedId = -1;
            revision++;
        }
        closePopovers();
        return result.clear;
    }

    function disarmClear(): void {
        clearArmed = false;
    }

    // Escape priority inside the editor: cancel text, close a popover or flyout,
    // deselect, and only then let the owner close the editor.
    function escapePressed(): bool {
        if (textEditing) {
            cancelText();
            return true;
        }
        if (inkOpen || toolMenu >= 0) {
            closePopovers();
            return true;
        }
        if (selectedId >= 0) {
            selectedId = -1;
            return true;
        }
        return false;
    }

    // Runs the keys that only change this state. Returns "handled" for those,
    // "copy" or "save" for the keys the owner must act on, and "" for a key the
    // editor ignores. A stroke being drawn ignores keys. Text being typed keeps
    // editing keys for the text control, but export keys still reach the owner.
    function shortcut(key: int, ctrl: bool, shift: bool, alt: bool): string {
        const result = Logic.shortcut(key, ctrl, shift, alt);
        if (!result || draft || moving)
            return "";
        if (textEditing && result.action !== "copy" && result.action !== "save")
            return "";
        if (result.action === "tool")
            setTool(result.tool);
        else if (result.action === "fill")
            toggleFill();
        else if (result.action === "delete")
            deleteSelected();
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
