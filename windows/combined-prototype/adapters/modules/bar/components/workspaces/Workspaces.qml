import QtQuick
import Quickshell
import Caelestia.Config
import qs.components

// Keep upstream workspace content and motion intact. Only the Windows graph
// adds the bounded running-app pill below it.
Column {
    id: root

    required property ShellScreen screen
    required property bool fullscreen

    readonly property Item owningBar: parent?.parent ?? null
    readonly property real rowSize: Tokens.sizes.bar.innerWidth - Tokens.padding.small
    readonly property real appBudget: {
        const bar = owningBar;
        if (!bar || !bar.height)
            return rowSize * 5 + Tokens.padding.small * 2;
        const entries = bar.children.filter(c => c.entryId && c.entryId !== "spacer" && c.item !== root);
        // The active title already elides to its available height. Reserve a
        // useful title area rather than depending on that reciprocal binding.
        const used = entries.reduce((sum, entry) => sum + (entry.entryId === "activeWindow"
            ? rowSize * 3 : (entry.item?.nonAnimHeight ?? entry.implicitHeight)), 0);
        const free = bar.height - used - workspaceContent.implicitHeight
            - bar.vPadding * 2 - bar.spacing * (bar.children.length - 1) - spacing;
        const rows = Math.max(1, Math.min(5,
            Math.floor((free - Tokens.padding.small * 2) / rowSize)));
        return rows * rowSize + Tokens.padding.small * 2;
    }

    spacing: runningApps.implicitHeight > 0 ? Tokens.spacing.medium : 0
    // Column derives its implicit width from WorkspacesContent, which already
    // reserves the bar's inner width.

    // The bar dispatcher reaches the running-app viewport through this entry.
    // Return true when the wheel belongs to the pill, including a short list
    // that must still consume the event.
    function handleWheel(y: real, angleDelta: point): bool {
        if (!runningApps.visible || y < runningApps.y || y >= runningApps.y + runningApps.height)
            return false;
        return runningApps.handleWheel(angleDelta);
    }

    WorkspacesContent {
        id: workspaceContent
        screen: root.screen
        fullscreen: root.fullscreen
    }

    RunningApps {
        id: runningApps
        maximumHeight: root.appBudget
        rowSize: root.rowSize
        visible: !root.fullscreen
        onInteractionStarted: root.owningBar?.popouts.close()
    }
}
