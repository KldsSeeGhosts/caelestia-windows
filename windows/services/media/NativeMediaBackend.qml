import QtQuick
import Quickshell.Services.Mpris

// Loaded by URL only after Players.enabled. Referencing the Mpris singleton
// constructs the GSMTC backend: its worker thread starts after the first frame
// and begins session observation; artwork sessions may be written to the
// process cache location's mpris-art directory. Construction sends no
// transport command.
//
// The pinned backend reports its own lifecycle. ready stays false until a
// successful GetSessions scan and becomes true with an empty lastError even
// when no sessions are open. An init_apartment, RequestAsync, GetSessions or
// later scan failure sets ready=false and publishes the failed operation with
// its HRESULT. Player snapshots can remain published while ready=false, so
// PlayersService hides them until the next successful scan. There is no
// per-command result: failed transport requests are logged by the worker only.
QtObject {
    id: root

    readonly property bool ready: Mpris.ready
    readonly property string lastError: Mpris.lastError

    readonly property var players: Mpris.players
}
