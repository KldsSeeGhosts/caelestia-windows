import QtQuick

// Windows adaptation of the bounded parts of services/Players.qml. This object
// has no native imports, timers, IPC, shortcuts, toasts, or process calls, and
// it exposes no transport methods: playback commands belong to the original UI
// components, which the host disables through a localized hook. Backends may be
// injected in tests.
//
// The pinned backend (2dff3ef2) distinguishes backend lifecycle from the
// session count: Mpris.ready is false until a successful session enumeration
// and Mpris.lastError carries the failed operation and HRESULT. A healthy scan
// with no open sessions is ready=true with an empty error. Native player
// snapshots can remain published after a later scan failure, so every list and
// control projection is gated on ready, never on the presence of objects.
QtObject {
    id: root

    // The injected backend is the NativeMediaBackend facade (or a test fake)
    // exposing: ready (bool), lastError (string), players (model with .values
    // of MprisPlayer-like objects).
    property var backend: null
    property bool enabled: false
    property bool controlsEnabled: false

    // A loader can supply a known component failure. Native status is observed
    // through nativeReady/nativeError instead.
    property string backendError: ""

    // Injected from GlobalConfig by the singleton wrapper so this object can be
    // staged without the configuration module in offscreen fixtures.
    property string defaultPlayer: ""
    property var playerAliases: []

    // Native lifecycle. nativeReady is the backend's own successful-scan flag;
    // a truthy non-boolean is not accepted. A component load failure overrides
    // it, because no native status exists in that state.
    readonly property bool nativeReady: enabled && !backendError && backend?.ready === true
    readonly property bool backendReady: nativeReady

    // A native error is only meaningful while the backend is not ready. A
    // healthy scan reports an empty error, and a stale error from an earlier
    // failure must not survive recovery.
    readonly property string nativeError: {
        if (!enabled || !backend || backend.ready === true)
            return "";

        const error = backend.lastError;
        return typeof error === "string" ? error : "";
    }

    // lastError is the one error string consumers may display: the component
    // load failure, or the backend's operation/HRESULT while unavailable.
    readonly property string lastError: {
        if (!enabled)
            return "";
        if (backendError)
            return backendError;
        return nativeError;
    }

    // The native model can retain snapshots while unavailable; hide all of
    // them unless the backend has completed a successful scan. Non-object
    // entries are rejected rather than projected as players.
    readonly property var list: {
        if (!nativeReady)
            return [];

        const values = backend?.players?.values;
        if (!values)
            return [];
        return values.filter(player => player && typeof player === "object");
    }
    readonly property int playerCount: list.length

    // Upstream selection order, with a stale-selection guard: a manual choice
    // only wins while that exact object is still observed. Removed sessions,
    // foreign objects and stale snapshots fall back to the configured default
    // alias identity and then to the first observed player.
    property var manualActive: null
    readonly property var active: {
        if (!nativeReady || list.length === 0)
            return null;
        if (manualActive && list.indexOf(manualActive) >= 0)
            return manualActive;
        return list.find(player => getIdentity(player) === defaultPlayer) ?? list[0] ?? null;
    }

    // Five distinct states. "no-sessions" is a healthy backend with an empty
    // session list; it is not an error. "unavailable" always has a lastError.
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!backend)
            return "loading";
        if (backend.ready === true)
            return playerCount > 0 ? "observed" : "no-sessions";
        if (nativeError)
            return "unavailable";
        return "loading";
    }
    readonly property bool ready: nativeReady
    readonly property bool sessionsObserved: status === "observed"
    readonly property bool noSessions: status === "no-sessions"

    readonly property string reason: {
        if (!enabled)
            return "Windows media is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows media backend.";
        if (status === "unavailable")
            return "The Windows media backend is unavailable: " + nativeError
                + " Media players and controls stay hidden until a successful session scan.";
        if (status === "loading")
            return "Waiting for the Windows media backend to report its first session scan.";
        if (status === "no-sessions")
            return "Windows media is observable; no media sessions are currently open.";
        return "Windows media is observable: " + playerCount + " session(s) observed. "
            + (controlsEnabled
            ? "Playback control requests may be sent for players whose native capability flags allow it; the backend does not report a per-command result."
            : "Playback controls are disabled for read-only observation.");
    }

    // Truthful unsupported actions at the pinned backend: GSMTC has no stop,
    // raise, quit, openUri, or player-volume control. MprisPlayer carries the
    // same per-player constants (canQuit/canRaise/canSetFullscreen false,
    // volumeSupported false); these service-level flags exist so consumers do
    // not need a player object to learn that. None of these can report success.
    readonly property bool stopSupported: false
    readonly property bool raiseSupported: false
    readonly property bool quitSupported: false
    readonly property bool openUriSupported: false
    readonly property bool volumeSupported: false

    function getIdentity(player): string {
        if (!player)
            return "";
        const identity = typeof player.identity === "string" ? player.identity : "";
        const alias = playerAliases?.find(a => a && a.from === identity);
        return alias?.to ?? identity;
    }

    // Preserved upstream fallback. The pinned backend's metadata map carries no
    // "xesam:url", so the YouTube branch cannot fire until the backend reports
    // more fields; trackArtUrl (the native art cache) is the working source.
    function getArtUrl(player): string {
        if (!player)
            return "";
        const artUrl = player.trackArtUrl;
        if (typeof artUrl === "string" && artUrl.length > 0)
            return artUrl;

        const url = player.metadata?.["xesam:url"] ?? "";
        if (typeof url === "string" && url.startsWith("https://www.youtube.com/watch")) {
            const id = url.match(/[?&]v=([\w-]{11})/)?.[1];
            return id ? `https://img.youtube.com/vi/${id}/hqdefault.jpg` : "";
        }
        return "";
    }

    function isListed(player): bool {
        return !!player && list.indexOf(player) >= 0;
    }

    // Whether an explicit transport request may be sent for this player.
    // Observation (list, metadata, timeline, capabilities) needs only the
    // observation opt-in; controls need the separate opt-in and the native
    // per-player canControl flag. This only gates a request: the backend logs
    // a failed command and does not expose a per-command result.
    function canControl(player): bool {
        return controlsEnabled && ready && isListed(player) && player.canControl === true;
    }

    // Per-capability gates. The original component checks the native flags
    // directly; these helpers make the same contract explicit for hosts and
    // tests without inventing a result.
    function canPlay(player): bool {
        return canControl(player) && player.canPlay === true;
    }

    function canPause(player): bool {
        return canControl(player) && player.canPause === true;
    }

    function canTogglePlaying(player): bool {
        return canControl(player) && player.canTogglePlaying === true;
    }

    function canSeek(player): bool {
        return canControl(player) && player.canSeek === true && player.positionSupported === true;
    }

    function canGoNext(player): bool {
        return canControl(player) && player.canGoNext === true;
    }

    function canGoPrevious(player): bool {
        return canControl(player) && player.canGoPrevious === true;
    }

    function canSetShuffle(player): bool {
        return canControl(player) && player.shuffleSupported === true;
    }

    function canSetLoop(player): bool {
        return canControl(player) && player.loopSupported === true;
    }

    // Unsupported actions never become controllable, even for a listed player
    // with controls enabled and a positive canControl snapshot.
    function canStop(player): bool {
        return false;
    }

    function canRaise(player): bool {
        return false;
    }

    function canQuit(player): bool {
        return false;
    }

    function canOpenUri(player): bool {
        return false;
    }

    function canSetVolume(player): bool {
        return false;
    }
}
