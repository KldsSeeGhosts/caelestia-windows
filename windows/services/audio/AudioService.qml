import QtQuick

// Windows adaptation of services/Audio.qml. This object has no native imports,
// startup writes, timers, IPC, or process calls. Backends may be injected in tests.
QtObject {
    id: root

    property var backend: null
    property bool enabled: false
    property bool controlsEnabled: false
    property real maxVolume: 1
    property real audioIncrement: 0.05

    // A loader or fixture can supply a known failure/denial. With an older
    // backend, ready=false cannot identify a Windows access-denied HRESULT.
    property string backendError: ""

    readonly property string lastError: backendError || errorText(backend?.lastError)
        || errorText(backend?.defaultSelectionError) || errorText(backend?.error)
    readonly property bool backendReady: enabled && !backendError && !!backend?.ready
    readonly property var _nodes: backendReady ? (backend?.nodes?.values ?? []) : []
    readonly property var sinks: _nodes.filter(node => node && !node.isStream && node.isSink && node.audio)
    readonly property var sources: _nodes.filter(node => node && !node.isStream && !node.isSink && node.audio)
    readonly property var streams: _nodes.filter(node => node && node.isStream && node.audio)

    // A default that is no longer in the current model must not escape as a
    // usable device while the native removal/default signals are in flight.
    readonly property var sink: sinks.indexOf(backend?.defaultAudioSink) >= 0 ? backend.defaultAudioSink : null
    readonly property var source: sources.indexOf(backend?.defaultAudioSource) >= 0 ? backend.defaultAudioSource : null
    readonly property bool outputAvailable: isNodeAvailable(sink)
    readonly property bool inputAvailable: isNodeAvailable(source)
    readonly property bool outputControlsAvailable: canControl(sink)
    readonly property bool inputControlsAvailable: canControl(source)

    readonly property bool available: backendReady && _nodes.some(node => isNodeAvailable(node))
    readonly property bool ready: status === "ready"
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!backend)
            return "initializing";
        if (!backendReady || !available)
            return "unavailable";
        return "ready";
    }
    readonly property string reason: {
        if (!enabled)
            return "Windows audio is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows audio backend.";
        if (!backendReady)
            return lastError || "The Windows audio backend is not ready; initialization or access may have failed. Native error details are not exposed.";
        if (!available)
            return "No ready audio devices or application streams are available. "
                + (_nodes.map(node => errorText(node?.audio?.controlError)).find(error => error.length > 0) || "");
        if (lastError)
            return "Windows audio is observable. " + lastError;
        const deviceError = _nodes.map(node => errorText(node?.audio?.controlError)).find(error => error.length > 0);
        if (deviceError)
            return "Windows audio reported a device error: " + deviceError;
        if (!controlsEnabled)
            return "Windows audio is ready with controls disabled.";
        return "Windows audio is observable; control availability is checked separately for each device.";
    }
    readonly property string outputReason: outputAvailable ? "" : (ready ? "No ready default audio output is available." : reason)
    readonly property string inputReason: inputAvailable ? "" : (ready ? "No ready default audio input is available." : reason)

    readonly property bool muted: getStreamMuted(sink)
    readonly property real volume: getStreamVolume(sink)
    readonly property bool sourceMuted: getStreamMuted(source)
    readonly property real sourceVolume: getStreamVolume(source)
    readonly property real effectiveMaxVolume: Number.isFinite(maxVolume) ? Math.max(0, Math.min(1, maxVolume)) : 1

    // Native analysis providers are injected by Audio.qml after its explicit
    // opt-in. This facade never constructs capture or analysis itself; disabled
    // and unavailable reads keep the same read-only compatibility shape.
    property var cavaProvider: null
    property var beatProvider: null
    property int visualiserBars: 0

    readonly property QtObject cava: enabled && cavaProvider ? cavaProvider : unavailableCava
    readonly property QtObject beatTracker: enabled && beatProvider ? beatProvider : unavailableBeat

    readonly property QtObject unavailableCava: QtObject {
        readonly property bool available: false
        readonly property var values: Array(root.visualiserBars).fill(0)
    }
    readonly property QtObject unavailableBeat: QtObject {
        readonly property bool available: false
        readonly property real bpm: 0
    }

    function isNodeAvailable(node): bool {
        return backendReady && !!node && _nodes.indexOf(node) >= 0 && !!node.ready
            && !!node.audio && node.audio.stateAvailable !== false;
    }

    function canControl(node): bool {
        // Enumeration readiness alone does not prove Windows activated the
        // volume interface. Older backends with no capability fail closed.
        return controlsEnabled && ready && isNodeAvailable(node) && node.audio.controlAvailable === true;
    }

    function errorText(error): string {
        return typeof error === "string" ? error : "";
    }

    // Keep numeric arguments untyped: a real parameter would coerce strings,
    // null, and booleans before the finite-number guard can reject them.
    // The reviewed Windows backend reports synchronous control errors. A true
    // result means the request completed without such an error, not proof of
    // later hardware delivery. Native state/notifications remain authoritative.
    function setStreamVolume(stream, newVolume): bool {
        if (!canControl(stream) || !Number.isFinite(newVolume))
            return false;
        stream.audio.muted = false;
        if (errorText(stream.audio.controlError))
            return false;
        stream.audio.volume = Math.max(0, Math.min(effectiveMaxVolume, newVolume));
        return !errorText(stream.audio.controlError);
    }

    function setStreamMuted(stream, newMuted): bool {
        if (!canControl(stream) || typeof newMuted !== "boolean")
            return false;
        stream.audio.muted = newMuted;
        return !errorText(stream.audio.controlError);
    }

    function setVolume(newVolume): bool {
        return setStreamVolume(sink, newVolume);
    }

    function setSourceVolume(newVolume): bool {
        return setStreamVolume(source, newVolume);
    }

    function setMuted(newMuted): bool {
        return setStreamMuted(sink, newMuted);
    }

    function setSourceMuted(newMuted): bool {
        return setStreamMuted(source, newMuted);
    }

    function adjustVolume(node, amount, direction): bool {
        const step = amount === undefined ? audioIncrement : amount;
        if (!canControl(node) || !Number.isFinite(step) || step < 0 || !Number.isFinite(node.audio.volume))
            return false;
        // An explicit zero is a successful no-op, including while muted.
        if (step === 0)
            return true;
        return setStreamVolume(node, node.audio.volume + direction * step);
    }

    function incrementVolume(amount): bool {
        return adjustVolume(sink, amount, 1);
    }

    function decrementVolume(amount): bool {
        return adjustVolume(sink, amount, -1);
    }

    function incrementSourceVolume(amount): bool {
        return adjustVolume(source, amount, 1);
    }

    function decrementSourceVolume(amount): bool {
        return adjustVolume(source, amount, -1);
    }

    function setAudioSink(newSink): bool {
        if (!canControl(newSink) || sinks.indexOf(newSink) < 0)
            return false;
        backend.preferredDefaultAudioSink = newSink;
        return !errorText(backend.defaultSelectionError);
    }

    function setAudioSource(newSource): bool {
        if (!canControl(newSource) || sources.indexOf(newSource) < 0)
            return false;
        backend.preferredDefaultAudioSource = newSource;
        return !errorText(backend.defaultSelectionError);
    }

    function cycleNextAudioOutput(): bool {
        const outputs = sinks.filter(node => canControl(node));
        if (outputs.length === 0)
            return false;
        const nextIndex = (outputs.indexOf(sink) + 1) % outputs.length;
        return setAudioSink(outputs[nextIndex]);
    }

    function getStreamVolume(stream): real {
        if (!isNodeAvailable(stream) || !Number.isFinite(stream.audio.volume))
            return 0;
        return Math.max(0, Math.min(1, stream.audio.volume));
    }

    function getStreamMuted(stream): bool {
        return isNodeAvailable(stream) && !!stream.audio.muted;
    }

    function getStreamName(stream): string {
        if (!stream || _nodes.indexOf(stream) < 0)
            return "Unknown";
        return stream.properties?.["application.name"] || stream.description || stream.name || "Unknown application";
    }
}
