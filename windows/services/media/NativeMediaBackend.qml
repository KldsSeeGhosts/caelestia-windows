import QtQuick
import Quickshell.Services.Mpris

// Loaded by URL only after Players.enabled. Referencing the Mpris singleton
// constructs the GSMTC backend: its worker thread starts after the first frame
// and begins session observation; artwork sessions may be written to the
// process cache location's mpris-art directory. Construction sends no
// transport command. The pinned backend exposes no initialization result: a
// failed COM apartment init or GSMTC manager request logs a warning and leaves
// an empty player list, which this facade cannot distinguish from "no
// sessions" (audits/M2-MEDIA-BACKEND-GAPS.md).
QtObject {
    id: root

    // Completing construction only proves the facade loaded and the worker
    // thread was requested, not that GSMTC access succeeded.
    readonly property bool ready: true

    readonly property var players: Mpris.players
}
