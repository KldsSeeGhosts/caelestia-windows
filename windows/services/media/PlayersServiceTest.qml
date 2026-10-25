pragma ComponentBehavior: Bound

import QtQuick

// Standalone lifecycle fixture. Imports no Quickshell/native Mpris/configuration
// module, reads no environment or hardware, and never constructs Players.qml.
// Intended runner: powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and PlayersService.qml.
QtObject {
    id: test

    // Shapes mirror the pinned backend (2dff3ef2). Untyped fields let guards
    // receive invalid native-shaped values; the adapter must reject or pass
    // them through without inventing state.
    component FakePlayer: QtObject {
        property bool canControl: false
        property bool canPlay: false
        property bool canPause: false
        property bool canTogglePlaying: false
        property bool canSeek: false
        property bool canGoNext: false
        property bool canGoPrevious: false
        property bool canQuit: false
        property bool canRaise: false
        property bool volumeSupported: false
        property bool positionSupported: false
        property bool lengthSupported: false
        property bool shuffleSupported: false
        property bool loopSupported: false
        property bool isPlaying: false
        property string identity: ""
        property string desktopEntry: ""
        property string dbusName: ""
        property string trackTitle: ""
        property string trackArtist: ""
        property string trackAlbum: ""
        property string trackArtUrl: ""
        property var metadata: ({})
        property real position: 0
        property real length: 0
        property int uniqueId: 0
    }

    component FakeModel: QtObject {
        property var values: []
    }

    component FakeBackend: QtObject {
        property bool ready: false
        property string lastError: ""
        property var players: null
    }

    readonly property PlayersService service: PlayersService {}
    readonly property FakeBackend fixture: FakeBackend {}
    readonly property FakeModel model: FakeModel {}

    readonly property FakePlayer spotify: FakePlayer {
        identity: "Spotify"
        desktopEntry: "spotify"
        dbusName: "gsmtc:Spotify.exe#1"
        canControl: true
        canPlay: true
        canPause: true
        canTogglePlaying: true
        canSeek: true
        canGoNext: true
        canGoPrevious: true
        positionSupported: true
        lengthSupported: true
        shuffleSupported: true
        loopSupported: true
        isPlaying: true
        uniqueId: 1
        trackTitle: "Fixture Song"
        trackArtist: "Fixture Artist"
        trackAlbum: "Fixture Album"
        trackArtUrl: "file:///fixtures/cover.png"
        metadata: ({})
        position: 42.5
        length: 200
    }

    readonly property FakePlayer ytm: FakePlayer {
        identity: "com.github.th_ch.youtube_music"
        desktopEntry: "youtube-music"
        dbusName: "gsmtc:com.github.th_ch.youtube_music#2"
        canControl: true
        canPlay: true
        canTogglePlaying: true
        uniqueId: 2
    }

    readonly property FakePlayer bare: FakePlayer {
        identity: "UnknownApp"
        dbusName: "gsmtc:UnknownApp.exe#3"
        metadata: ({})
        uniqueId: 3
    }

    // Reports control but with a narrower capability set than spotify.
    readonly property FakePlayer limited: FakePlayer {
        identity: "LimitedApp"
        dbusName: "gsmtc:LimitedApp.exe#4"
        canControl: true
        canPause: true
        canSeek: true
        positionSupported: false
        shuffleSupported: false
        loopSupported: false
        uniqueId: 4
    }

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function close(actual, expected, message): void {
        check(Math.abs(actual - expected) < 0.000001, message + ": " + actual + " != " + expected);
    }

    function setPlayers(players): void {
        model.values = players;
    }

    function expectStatus(expected, message): void {
        check(service.status === expected,
            message + ": status " + service.status + " != " + expected + " (" + service.reason + ")");
    }

    function run(): void {
        // --- Safe construction ------------------------------------------------
        check(service.enabled === false && service.controlsEnabled === false
            && service.backend === null && service.backendError === "",
            "safe construction defaults");
        expectStatus("disabled", "explicit disabled state");
        check(service.reason.length > 0, "disabled reason");
        check(!service.nativeReady && !service.backendReady && !service.ready,
            "disabled is not ready");
        check(!service.noSessions && !service.sessionsObserved && service.playerCount === 0
            && service.list.length === 0 && service.active === null,
            "disabled has no players");
        check(service.lastError === "", "disabled has no error");
        check(!service.canControl(spotify) && !service.canPlay(spotify), "disabled cannot control");
        check(!service.stopSupported && !service.raiseSupported && !service.quitSupported
            && !service.openUriSupported && !service.volumeSupported,
            "unsupported actions are false while disabled");
        check(!service.canStop(spotify) && !service.canRaise(spotify)
            && !service.canQuit(spotify) && !service.canOpenUri(spotify)
            && !service.canSetVolume(spotify),
            "unsupported capability gates are false while disabled");

        // The adapter is observation-only: no transport/mutating method may
        // exist. QML property enumeration is not reliable, so check the exact
        // upstream MprisPlayer invokable names and preserved helpers.
        for (const name of ["getIdentity", "getArtUrl", "canControl", "canPlay",
            "canPause", "canTogglePlaying", "canSeek", "canGoNext", "canGoPrevious",
            "canSetShuffle", "canSetLoop", "canStop", "canRaise", "canQuit",
            "canOpenUri", "canSetVolume", "isListed"]) {
            check(typeof service[name] === "function", "missing preserved helper " + name);
        }
        for (const name of ["play", "pause", "stop", "next", "previous", "seek",
            "raise", "quit", "openUri", "togglePlaying", "setVolume", "setPlaying",
            "setPosition", "setShuffle", "setLoopState", "setActive", "selectPlayer",
            "cycleNext", "requestControl"]) {
            check(service[name] === undefined, "adapter exposes transport member " + name);
        }

        // --- Selection helpers do not need an enabled backend -----------------
        service.playerAliases = [
            {from: "com.github.th_ch.youtube_music", to: "YT Music"},
            null,
            {from: "BrokenAlias"}
        ];
        check(service.getIdentity(null) === "" && service.getIdentity(undefined) === "",
            "null identity is empty");
        check(service.getIdentity(spotify) === "Spotify", "plain identity read");
        check(service.getIdentity(ytm) === "YT Music", "alias identity mapping");
        check(service.getIdentity(bare) === "UnknownApp", "identity without alias");
        check(service.getIdentity({identity: "BrokenAlias"}) === "BrokenAlias",
            "alias without a target falls back to identity");

        check(service.getArtUrl(null) === "", "null art url is empty");
        check(service.getArtUrl(spotify) === "file:///fixtures/cover.png", "native art url read");
        check(service.getArtUrl(bare) === "", "no art without url or track art");
        check(service.getArtUrl({trackArtUrl: 5, metadata: {}}) === "",
            "invalid art url is ignored");
        const youtube = service.getArtUrl({
            trackArtUrl: "",
            metadata: {"xesam:url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}
        });
        check(youtube === "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
            "preserved upstream youtube fallback");
        check(service.getArtUrl({trackArtUrl: "", metadata: {"xesam:url": 7}}) === "",
            "invalid metadata url is ignored");
        check(service.getArtUrl({trackArtUrl: "", metadata: {}}) === "", "empty metadata art");

        // --- Enabled, no backend yet -----------------------------------------
        service.enabled = true;
        expectStatus("loading", "backend loading state");
        check(service.reason.indexOf("Windows media backend") >= 0,
            "loading reason names the backend wait");
        check(!service.nativeReady && !service.backendReady && !service.ready,
            "loading is not ready");
        check(service.list.length === 0 && service.active === null, "loading has no players");
        check(service.lastError === "", "loading has no error");
        service.controlsEnabled = true;
        check(!service.canControl(spotify), "loading cannot control even with the opt-in");
        service.controlsEnabled = false;

        // A known component failure is an explicit unavailable state.
        service.backendError = "Fixture component initialization failed";
        expectStatus("unavailable", "known component failure");
        check(service.reason === service.backendError && service.lastError === service.backendError,
            "component failure is reported verbatim");
        check(service.list.length === 0 && !service.canControl(spotify),
            "failed component controls nothing");
        service.backendError = "";

        // --- Present but unready backend, with stale snapshots ----------------
        service.backend = fixture;
        fixture.players = model;
        setPlayers([ytm, spotify, bare]);
        expectStatus("loading", "unready backend with empty error is loading");
        check(service.reason.indexOf("first session scan") >= 0,
            "unready backend reason states the scan wait");
        check(!service.nativeReady && service.list.length === 0 && service.active === null,
            "stale snapshots are hidden while the backend is not ready");
        service.controlsEnabled = true;
        check(!service.canControl(spotify), "stale snapshots cannot be controlled");
        service.controlsEnabled = false;

        fixture.lastError = "GSMTC GetSessions failed (HRESULT 0x80070005)";
        expectStatus("unavailable", "scan failure is unavailable");
        check(service.nativeError === fixture.lastError && service.lastError === fixture.lastError,
            "native operation and HRESULT are exposed");
        check(service.reason.indexOf("0x80070005") >= 0, "unavailable reason includes the native error");
        check(service.list.length === 0 && service.active === null
            && service.ready === false && !service.noSessions && !service.sessionsObserved,
            "unavailable hides retained player snapshots");

        // A successful scan is authoritative and clears a stale error.
        fixture.ready = true;
        expectStatus("observed", "successful scan with retained snapshots");
        check(service.nativeError === "" && service.lastError === "",
            "stale native error does not survive recovery");
        check(service.reason.indexOf("0x80070005") < 0, "recovered reason drops the stale error");
        fixture.lastError = "";

        // --- Healthy observation with no sessions -----------------------------
        setPlayers([]);
        expectStatus("no-sessions", "healthy empty scan");
        check(service.nativeReady && service.backendReady && service.ready,
            "healthy empty scan is ready");
        check(service.noSessions && !service.sessionsObserved && service.playerCount === 0
            && service.list.length === 0 && service.active === null,
            "healthy empty scan observes no sessions");
        check(service.reason.indexOf("no media sessions") >= 0,
            "empty scan reason is distinct from an error");
        check(service.lastError === "", "healthy empty scan has no error");

        // --- Observed sessions and upstream selection ordering ----------------
        setPlayers([ytm, spotify, bare]);
        expectStatus("observed", "session arrival is reactive");
        check(service.sessionsObserved && !service.noSessions && service.playerCount === 3,
            "session list and count");
        check(service.list.indexOf(ytm) === 0 && service.list.indexOf(spotify) === 1
            && service.list.indexOf(bare) === 2, "model order is preserved");
        check(service.active === ytm, "no configured default selects the first player");

        // A component failure overrides an otherwise healthy native snapshot.
        service.controlsEnabled = true;
        service.backendError = "Fixture component failure with live sessions";
        expectStatus("unavailable", "component failure overrides native health");
        check(service.list.length === 0 && service.active === null
            && service.lastError === service.backendError
            && !service.canControl(spotify),
            "component failure hides live sessions and blocks control");
        service.backendError = "";
        service.controlsEnabled = false;
        expectStatus("observed", "native observation recovers after a component failure");
        check(service.active === ytm, "selection recovers with the observed list");

        service.defaultPlayer = "Spotify";
        check(service.active === spotify, "default player selection");
        service.defaultPlayer = "YT Music";
        check(service.active === ytm, "alias-resolved default selection");
        service.defaultPlayer = "NoSuchPlayer";
        check(service.active === ytm, "unmatched default falls back to the first player");
        service.defaultPlayer = "";

        // Manual selection wins while that exact observed object exists.
        service.manualActive = bare;
        check(service.active === bare, "manual selection wins");
        setPlayers([spotify, bare, ytm]);
        check(service.active === bare, "manual selection survives reordering");
        service.defaultPlayer = "Spotify";
        setPlayers([spotify, ytm]);
        check(service.active === spotify, "removed manual selection falls back");
        service.manualActive = ytm;
        check(service.active === ytm, "stale foreign manual selection is ignored");
        service.manualActive = null;
        check(service.active === spotify, "cleared manual selection restores the rules");

        // --- Progressive metadata, art and timeline ---------------------------
        setPlayers([spotify]);
        service.defaultPlayer = "";
        check(service.active === spotify, "single player selected");
        check(service.active.trackTitle === "Fixture Song"
            && service.active.trackArtist === "Fixture Artist"
            && service.active.trackAlbum === "Fixture Album",
            "metadata read through active");
        spotify.trackTitle = "Fixture Song 2";
        spotify.trackArtist = "Fixture Artist 2";
        spotify.trackAlbum = "Fixture Album 2";
        spotify.uniqueId = 11;
        check(service.active.trackTitle === "Fixture Song 2"
            && service.active.trackArtist === "Fixture Artist 2"
            && service.active.trackAlbum === "Fixture Album 2"
            && service.active.uniqueId === 11,
            "progressive metadata updates are observed");
        close(service.active.position, 42.5, "position read through active");
        close(service.active.length, 200, "length read through active");
        spotify.position = 50.25;
        spotify.length = 210;
        spotify.isPlaying = false;
        close(service.active.position, 50.25, "position update is observed");
        close(service.active.length, 210, "length update is observed");
        check(service.active.isPlaying === false, "playback state update is observed");
        check(service.active.positionSupported && service.active.lengthSupported,
            "timeline support flags read through active");
        check(service.active.shuffleSupported && service.active.loopSupported,
            "shuffle and loop support flags read through active");
        check(service.active.canQuit === false && service.active.canRaise === false
            && service.active.volumeSupported === false,
            "per-player unsupported constants read through active");
        check(service.getArtUrl(service.active) === "file:///fixtures/cover.png",
            "native art reads through active");
        spotify.trackArtUrl = "";
        spotify.metadata = {"xesam:url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"};
        check(service.getArtUrl(service.active)
            === "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
            "youtube art fallback reads updated metadata");
        spotify.metadata = {};
        check(service.getArtUrl(service.active) === "", "cleared art reads empty");

        // --- Capability gates -------------------------------------------------
        service.controlsEnabled = false;
        check(!service.canControl(spotify), "controls default off");
        check(!service.canPlay(spotify) && !service.canPause(spotify)
            && !service.canTogglePlaying(spotify) && !service.canSeek(spotify)
            && !service.canGoNext(spotify) && !service.canGoPrevious(spotify)
            && !service.canSetShuffle(spotify) && !service.canSetLoop(spotify),
            "read-only mode disables every capability gate");

        service.controlsEnabled = true;
        check(service.canControl(spotify), "controls opt-in enables a listed player");
        check(service.canPlay(spotify) && service.canPause(spotify)
            && service.canTogglePlaying(spotify) && service.canSeek(spotify)
            && service.canGoNext(spotify) && service.canGoPrevious(spotify)
            && service.canSetShuffle(spotify) && service.canSetLoop(spotify),
            "native positive capabilities pass through");
        check(!service.canControl(ytm) && !service.canPlay(ytm),
            "unlisted player cannot be controlled");
        check(!service.canControl(null) && !service.canControl(undefined)
            && !service.canControl({canControl: true}),
            "invalid or foreign players cannot be controlled");

        setPlayers([limited]);
        check(service.canControl(limited), "native canControl alone permits listing");
        check(!service.canPlay(limited) && service.canPause(limited)
            && !service.canTogglePlaying(limited) && !service.canSeek(limited),
            "missing native capabilities stay false");
        check(!service.canGoNext(limited) && !service.canGoPrevious(limited)
            && !service.canSetShuffle(limited) && !service.canSetLoop(limited),
            "narrow capabilities stay false");
        check(!service.canStop(limited) && !service.canRaise(limited)
            && !service.canQuit(limited) && !service.canOpenUri(limited)
            && !service.canSetVolume(limited),
            "unsupported actions never become controllable");
        check(!service.stopSupported && !service.raiseSupported && !service.quitSupported
            && !service.openUriSupported && !service.volumeSupported,
            "unsupported service flags stay false");

        setPlayers([{canControl: 1, canPlay: true, canPause: true}]);
        check(!service.canControl(service.list[0]) && !service.canPlay(service.list[0]),
            "non-boolean native capabilities are rejected");

        // --- Removal, unavailability and recovery -----------------------------
        setPlayers([spotify, bare]);
        service.defaultPlayer = "Spotify";
        service.manualActive = spotify;
        check(service.active === spotify, "selected player before removal");
        fixture.ready = false;
        fixture.lastError = "";
        expectStatus("loading", "backend loss is not reported as no sessions");
        check(service.list.length === 0 && service.active === null,
            "backend loss hides observed players");
        check(!service.canControl(spotify), "backend loss disables control");
        fixture.ready = true;
        expectStatus("observed", "same retained snapshot recovers");
        check(service.active === spotify, "valid manual selection survives a scan outage");
        setPlayers([]);
        expectStatus("no-sessions", "all sessions removed");
        check(service.active === null && !service.canControl(spotify),
            "removed selection clears and cannot be controlled");
        setPlayers([spotify]);
        expectStatus("observed", "session re-arrival is reactive");
        check(service.active === spotify, "recovered default selection");
        service.manualActive = null;

        // --- Backend shape robustness ----------------------------------------
        service.backend = {};
        expectStatus("loading", "backend without a status is loading");
        service.backend = {ready: "true", lastError: "", players: {values: [spotify]}};
        expectStatus("loading", "non-boolean ready is not trusted");
        service.backend = {ready: true, players: null};
        expectStatus("no-sessions", "ready backend with no model is healthy empty");
        service.backend = {ready: true, players: {values: null}};
        expectStatus("no-sessions", "empty model values are healthy empty");
        check(service.list.length === 0 && service.active === null, "empty model has no active player");
        service.backend = {ready: true, players: {values: [null, spotify, undefined]}};
        expectStatus("observed", "invalid model entries are filtered");
        check(service.playerCount === 1 && service.active === spotify,
            "non-object entries are not players");
        service.backend = {ready: false, lastError: 42, players: {values: [spotify]}};
        expectStatus("loading", "non-string native errors are ignored");
        check(service.lastError === "", "non-string native error is not displayed");

        service.backend = fixture;
        setPlayers([spotify]);
        fixture.ready = true;
        fixture.lastError = "";
        service.defaultPlayer = "";

        // --- Disable clears every observation and control ---------------------
        service.controlsEnabled = false;
        service.enabled = false;
        expectStatus("disabled", "disable returns to disabled");
        check(!service.nativeReady && !service.ready && !service.noSessions
            && !service.sessionsObserved && service.playerCount === 0
            && service.list.length === 0 && service.active === null,
            "disable clears observed state");
        check(service.lastError === "", "disable clears the native error");
        check(!service.canControl(spotify) && !service.canPlay(spotify)
            && !service.canStop(spotify), "disable clears control");
        service.controlsEnabled = true;
        check(!service.canControl(spotify), "controls opt-in cannot outlive observation");

        console.log("CAELESTIA_MEDIA_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_MEDIA_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
