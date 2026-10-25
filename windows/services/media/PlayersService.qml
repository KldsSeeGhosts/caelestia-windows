import QtQuick

// Windows adaptation of the bounded parts of services/Players.qml. This object
// has no native imports, timers, IPC, shortcuts, toasts, or process calls, and
// it exposes no transport methods: playback commands belong to the original UI
// components, which a read-only host disables through localized hooks.
// Backends may be injected in tests.
QtObject {
    id: root

    // The injected backend is the NativeMediaBackend facade (or a test fake)
    // exposing: ready (bool), players (model with .values of MprisPlayer-like
    // objects). The pinned backend has no initialization/error fields; see
    // audits/M2-MEDIA-BACKEND-GAPS.md.
    property var backend: null
    property bool enabled: false
    property bool controlsEnabled: false

    // A loader or fixture can supply a known component failure. A failed GSMTC
    // request is NOT observable: the native worker logs it and keeps an empty
    // player list, so "ready" below never claims confirmed session health.
    property string backendError: ""

    // Injected from GlobalConfig by the singleton wrapper so this object can be
    // staged without the configuration module in offscreen fixtures.
    property string defaultPlayer: ""
    property var playerAliases: []

    readonly property bool backendReady: enabled && !backendError && !!backend?.ready
    readonly property var list: backendReady ? (backend?.players?.values ?? []) : []
    readonly property int playerCount: list.length
    readonly property bool sessionsObserved: playerCount > 0

    // Upstream selection order, guarded against a removed manual selection the
    // way the audio adapter guards a stale default: a player that left the
    // model must not stay selectable.
    property var manualActive: null
    readonly property var active: {
        if (manualActive && list.indexOf(manualActive) >= 0)
            return manualActive;
        return list.find(player => getIdentity(player) === defaultPlayer) ?? list[0] ?? null;
    }

    // Truthful unsupported actions at the pinned backend: GSMTC has no stop,
    // raise, quit, openUri, or player-volume control. MprisPlayer carries the
    // same per-player constants (canQuit/canRaise/canSetFullscreen false,
    // volumeSupported false); these service-level flags exist so consumers do
    // not need a player object to learn that.
    readonly property bool stopSupported: false
    readonly property bool raiseSupported: false
    readonly property bool quitSupported: false
    readonly property bool openUriSupported: false
    readonly property bool volumeSupported: false

    function getIdentity(player): string {
        if (!player)
            return "";
        const alias = playerAliases.find(a => a.from === player.identity);
        return alias?.to ?? player.identity;
    }

    // Preserved upstream fallback. The pinned backend's metadata map carries no
    // "xesam:url", so the YouTube branch cannot fire until the backend reports
    // more fields; trackArtUrl (the native art cache) is the working source.
    function getArtUrl(player): string {
        if (!player)
            return "";
        if (player.trackArtUrl)
            return player.trackArtUrl;

        const url = player.metadata?.["xesam:url"] ?? "";
        if (url.startsWith("https://www.youtube.com/watch")) {
            const id = url.match(/[?&]v=([\w-]{11})/)?.[1];
            return id ? `https://img.youtube.com/vi/${id}/hqdefault.jpg` : "";
        }
        return "";
    }

    // Whether explicit transport interaction with this player may be sent.
    // Observation (list, metadata, timeline, capabilities) needs only
    // enabled; controls need the separate opt-in.
    function canControl(player): bool {
        return controlsEnabled && ready && !!player && list.indexOf(player) >= 0;
    }

    readonly property bool ready: status === "ready"
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!backend)
            return "initializing";
        if (!backendReady)
            return "unavailable";
        return "ready";
    }
    readonly property string reason: {
        if (!enabled)
            return "Windows media status is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows media backend.";
        if (!backendReady)
            return "The Windows media backend is not ready; initialization or access may have failed. Native error details are not exposed.";
        if (!sessionsObserved)
            return "No media sessions observed. The backend does not report GSMTC initialization failures, so an empty list can also mean the media backend is unavailable.";
        return "Windows media is observable."
            + (controlsEnabled ? "" : " Playback controls are disabled.");
    }
}
