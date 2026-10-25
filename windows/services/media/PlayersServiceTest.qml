pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture. Imports no Quickshell/native Mpris/configuration module,
// reads no environment or hardware, and never constructs Players.qml.
// Intended runner: powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and PlayersService.qml.
QtObject {
    id: test

    // Shapes mirror the pinned backend (audits/M2-MEDIA-BACKEND-GAPS.md):
    // untyped fields let guards receive invalid native-shaped values; the
    // adapter must reject or pass them through without inventing state.
    component FakePlayer: QtObject {
        property bool canControl: false
        property bool canPlay: false
        property bool canPause: false
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
        uniqueId: 2
    }

    readonly property FakePlayer bare: FakePlayer {
        identity: "UnknownApp"
        dbusName: "gsmtc:UnknownApp.exe#3"
        metadata: ({})
        uniqueId: 3
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

    function run(): void {
        check(service.enabled === false && service.backend === null && service.backendError === "",
            "safe construction defaults");
        check(service.status === "disabled" && service.reason.length > 0, "explicit disabled state");
        check(!service.backendReady && service.list.length === 0 && service.active === null,
            "disabled has no players");
        check(!service.controlsEnabled && !service.canControl(spotify), "disabled cannot control");
        check(!service.stopSupported && !service.raiseSupported && !service.quitSupported
            && !service.openUriSupported && !service.volumeSupported,
            "unsupported actions are false while disabled");

        // The adapter is observation-only: introspect its function members and
        // require that no transport/mutating method exists at all. Constant
        // unsupported flags such as stopSupported are plain booleans.
        const members = Object.keys(service).concat(Object.getOwnPropertyNames(service));
        check(members.length > 0, "introspection enumerates adapter members");
        const functions = [...new Set(members.filter(key =>
            typeof service[key] === "function" && !key.endsWith("Changed")))];
        check(functions.indexOf("getIdentity") >= 0 && functions.indexOf("getArtUrl") >= 0
            && functions.indexOf("canControl") >= 0, "preserved API functions are present");
        const mutating = functions.filter(key =>
            /^(set|select|apply|write|cycle|request|toggle|increment|decrement|play|pause|next|previous|stop|seek|skip)/i.test(key));
        check(mutating.length === 0, "adapter exposes no transport methods: " + JSON.stringify(mutating));

        // Selection helpers must not need an enabled backend.
        service.playerAliases = [{from: "com.github.th_ch.youtube_music", to: "YT Music"}];
        check(service.getIdentity(null) === "", "null identity is empty");
        check(service.getIdentity(spotify) === "Spotify", "plain identity read");
        check(service.getIdentity(ytm) === "YT Music", "alias identity mapping");
        check(service.getArtUrl(null) === "", "null art url is empty");
        check(service.getArtUrl(spotify) === "file:///fixtures/cover.png", "native art url read");
        check(service.getArtUrl(bare) === "", "no art without url or track art");
        const youtube = service.getArtUrl({
            trackArtUrl: "",
            metadata: {"xesam:url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}
        });
        check(youtube === "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
            "preserved upstream youtube fallback");
        check(service.getArtUrl({trackArtUrl: "", metadata: {}}) === "", "empty metadata art");

        service.enabled = true;
        check(service.status === "initializing" && service.reason.length > 0, "backend loading state");
        check(service.list.length === 0 && service.active === null, "initializing has no players");

        // Known component failure is the one honest "unavailable".
        service.backendError = "Fixture component initialization failed";
        check(service.status === "unavailable" && service.reason === service.backendError,
            "known initialization failure");
        check(service.list.length === 0 && !service.canControl(spotify), "failed load controls nothing");
        service.backendError = "";

        // A present but unready backend is unavailable, not "no sessions".
        service.backend = fixture;
        fixture.players = model;
        check(service.status === "unavailable" && !service.backendReady && service.active === null,
            "unready backend is honest");
        check(service.list.length === 0, "unready backend hides players");

        // Ready with zero players: observation works, but session health is
        // unknown because the backend reports no GSMTC initialization result.
        fixture.ready = true;
        check(service.status === "ready" && service.backendReady, "ready backend");
        check(!service.sessionsObserved && service.list.length === 0, "no sessions observed");
        check(service.reason.indexOf("initialization failures") >= 0,
            "empty list reason states the unknown-health caveat: " + service.reason);
        check(service.active === null, "no sessions select no active player");

        // Identity-based selection over an observed list.
        setPlayers([ytm, spotify, bare]);
        check(service.sessionsObserved && service.playerCount === 3, "session arrival is reactive");
        check(service.reason.indexOf("observable") >= 0, "ready reason reports observation");
        service.defaultPlayer = "Spotify";
        check(service.active === spotify, "default player selection");
        service.defaultPlayer = "YT Music";
        check(service.active === ytm, "alias-resolved default selection");
        service.defaultPlayer = "NoSuchPlayer";
        check(service.active === ytm, "unmatched default falls back to first");
        service.defaultPlayer = "";

        // Manual selection wins, and a stale/foreign selection cannot stick.
        service.manualActive = bare;
        check(service.active === bare, "manual selection wins");
        setPlayers([ytm, spotify]);
        check(service.active === spotify, "removed manual selection falls back");
        service.manualActive = null;
        check(service.active === spotify, "cleared manual selection restores rules");

        // Metadata and timeline pass through the active player unchanged.
        setPlayers([spotify]);
        check(service.active === spotify, "single player selected");
        check(service.active.trackTitle === "Fixture Song", "title read through active");
        check(service.active.trackArtist === "Fixture Artist", "artist read through active");
        check(service.active.trackAlbum === "Fixture Album", "album read through active");
        check(service.active.isPlaying === true, "playback state read through active");
        close(service.active.position, 42.5, "position read through active");
        close(service.active.length, 200, "length read through active");
        check(service.active.positionSupported && service.active.lengthSupported,
            "timeline support flags read through active");
        check(service.active.canQuit === false && service.active.canRaise === false
            && service.active.volumeSupported === false,
            "per-player unsupported constants read through active");

        // Capability gating is observable, and controls are a separate opt-in.
        check(service.canControl(spotify) === false, "controls default off");
        service.controlsEnabled = true;
        check(service.canControl(spotify) === true, "controls opt-in enables a listed player");
        check(service.canControl(ytm) === false, "unlisted player cannot be controlled");
        check(service.canControl(null) === false, "null player cannot be controlled");
        fixture.ready = false;
        check(service.canControl(spotify) === false, "unready backend cannot be controlled");
        fixture.ready = true;

        // Removal, replacement and recovery are observed, never remembered.
        setPlayers([]);
        check(service.active === null && !service.sessionsObserved, "all sessions removed");
        setPlayers([spotify]);
        check(service.active === spotify, "session re-arrival is reactive");
        const spotify2 = spotify;
        check(service.active === spotify2, "same object stays selected");
        setPlayers([bare, spotify]);
        check(service.active === spotify, "default rule still wins after reorder");
        fixture.ready = false;
        check(service.list.length === 0 && service.active === null, "backend loss clears observation");
        fixture.ready = true;
        check(service.active === spotify, "backend recovery restores selection");

        service.controlsEnabled = false;
        service.enabled = false;
        check(service.status === "disabled" && !service.backendReady && service.list.length === 0,
            "disable clears observed state");
        check(service.active === null && !service.canControl(spotify), "disable clears selection and control");
        console.log("CAELESTIA_MEDIA_FIXTURE_PASS " + JSON.stringify({ assertions: assertions }));
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
