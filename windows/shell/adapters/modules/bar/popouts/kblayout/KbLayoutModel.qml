pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Windows
import Caelestia.I18n

// Windows adapter for modules/bar/popouts/kblayout/KbLayoutModel.qml. It keeps
// the upstream model's surface (visibleModel, activeLabel, activeIndex,
// start(), refresh(), switchTo()) so the upstream KbLayout view, its layout and
// its motion stay unchanged.
//
// The Linux model runs hyprctl/xmllint, reads XKB files and disables entries
// after XKB's fourth layout. This adapter reads the native Keyboard singleton
// instead: `layouts` is GetKeyboardLayoutList with localized locale and
// layout names, `currentLayoutIndex` follows the foreground layout through the
// singleton's change notifications, and `switchTo()` asks the backend to post
// WM_INPUTLANGCHANGEREQUEST to the foreground window. There is no process,
// timer, XKB file or layout cap here.
Item {
    id: model

    // Injected by the offscreen fixture. The production view leaves it null so
    // Component.onCompleted resolves the native singleton.
    property QtObject keyboard: null

    property alias visibleModel: visibleModel
    property string activeLabel: ""
    property int activeIndex: -1

    function start(): void {
        if (!keyboard)
            keyboard = Keyboard;
        _rebuild();
        _applyCurrent();
    }

    function refresh(): void {
        _rebuild();
        _applyCurrent();
    }

    // "requested" only means the backend posted the switch; the active entry
    // stays unchanged until its notification arrives. "denied" is reported
    // for UIPI/PostMessage failure without changing the selection.
    function switchTo(idx: int): string {
        if (!keyboard)
            return "no-target";
        return keyboard.activateLayoutAt(idx);
    }

    function _label(layout): string {
        const layoutName = String(layout.layoutName ?? "").trim();
        const code = String(layout.code ?? "").trim().toUpperCase();
        const name = String(layout.shortName ?? layout.name ?? "").trim();
        // TRANSLATORS: %1 = keyboard layout name or code, %2 = language and region
        return Tr.trCtx("%1 - %2", "keyboard layout code and name").arg(layoutName || code).arg(name || code);
    }

    function _rebuild(): void {
        layoutsModel.clear();
        if (!keyboard)
            return;

        const layouts = keyboard.layouts ?? [];
        for (let i = 0; i < layouts.length; i++) {
            const layout = layouts[i] ?? {};
            layoutsModel.append({
                layoutIndex: i,
                token: String(layout.code ?? ""),
                label: _label(layout)
            });
        }
    }

    function _applyCurrent(): void {
        const index = keyboard ? keyboard.currentLayoutIndex : -1;
        let label = "";
        if (index >= 0 && index < layoutsModel.count)
            label = layoutsModel.get(index).label;
        else if (keyboard && keyboard.currentLayoutName)
            label = String(keyboard.currentLayoutName);

        activeIndex = index;
        activeLabel = label;
        _rebuildVisible();
    }

    function _rebuildVisible(): void {
        visibleModel.clear();
        for (let i = 0; i < layoutsModel.count; i++) {
            const item = layoutsModel.get(i);
            if (item.layoutIndex !== activeIndex)
                visibleModel.append(item);
        }
    }

    visible: false

    Component.onCompleted: {
        if (!keyboard)
            keyboard = Keyboard;
    }

    // The singleton owns the observation; these notifications avoid a QML
    // polling loop and keep the popout current while it is open.
    Connections {
        target: model.keyboard

        function onLayoutsChanged(): void {
            model._rebuild();
            model._applyCurrent();
        }

        function onCurrentLayoutChanged(): void {
            model._applyCurrent();
        }
    }

    ListModel {
        id: visibleModel
    }

    ListModel {
        id: layoutsModel
    }
}
