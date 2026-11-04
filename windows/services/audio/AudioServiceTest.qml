pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture. Imports no Quickshell/native audio/configuration module,
// reads no environment or hardware, and never constructs Audio.qml.
// Intended runner: powershell -NoProfile -File windows/scripts/Test-AudioService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and AudioService.qml.
QtObject {
    id: test

    component FakeAudio: QtObject {
        property bool controlAvailable: true
        property bool stateAvailable: true
        property string controlError: ""
        property real volume: 0.4
        property bool muted: true
        property int volumeChanges: 0
        property int muteChanges: 0
        onVolumeChanged: volumeChanges++
        onMutedChanged: muteChanges++
    }

    component FakeNode: QtObject {
        // QML reserves the id binding; this models a native node's numeric id
        // without relying on it for membership/identity checks.
        property int nodeId: 0
        property bool ready: true
        property bool isSink: false
        property bool isStream: false
        property string name: ""
        property string description: ""
        property var properties: ({})
        property QtObject audio: FakeAudio {}
    }

    component FakeBackend: QtObject {
        property bool ready: false
        property string lastError: ""
        property string defaultSelectionError: ""
        property bool rejectSelection: false
        property QtObject nodes: QtObject {
            property var values: []
        }
        property var defaultAudioSink: null
        property var defaultAudioSource: null
        property var preferredDefaultAudioSink: null
        property var preferredDefaultAudioSource: null
        property int sinkChanges: 0
        property int sourceChanges: 0
        onPreferredDefaultAudioSinkChanged: {
            sinkChanges++;
            defaultSelectionError = rejectSelection ? "Fixture routing denied" : "";
            if (!rejectSelection)
                defaultAudioSink = preferredDefaultAudioSink;
        }
        onPreferredDefaultAudioSourceChanged: {
            sourceChanges++;
            defaultSelectionError = rejectSelection ? "Fixture routing denied" : "";
            if (!rejectSelection)
                defaultAudioSource = preferredDefaultAudioSource;
        }
    }

    readonly property AudioService service: AudioService {}
    readonly property FakeBackend fixture: FakeBackend {}
    readonly property QtObject unverifiedAudio: QtObject {
        property real volume: 0.4
        property bool muted: true
        property int volumeChanges: 0
        property int muteChanges: 0
    }
    readonly property FakeNode speaker: FakeNode {
        nodeId: 1
        isSink: true
        name: "speaker"
        description: "Speakers"
    }
    readonly property FakeNode headset: FakeNode {
        nodeId: 2
        isSink: true
        name: "headset"
    }
    readonly property FakeNode microphone: FakeNode {
        nodeId: 3
        name: "microphone"
    }
    readonly property FakeNode stream: FakeNode {
        nodeId: 4
        isStream: true
        name: "stream-name"
        description: "Stream description"
        properties: ({ "application.name": "Fixture player" })
    }
    readonly property FakeNode warming: FakeNode {
        nodeId: 5
        isSink: true
        ready: false
    }
    readonly property FakeNode noAudio: FakeNode {
        nodeId: 6
        audio: null
    }
    readonly property FakeNode replacement: FakeNode {
        nodeId: 1
        isSink: true
        name: "replacement"
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

    function observedWrites(): string {
        return JSON.stringify([speaker, headset, microphone, stream, warming, replacement].map(node => [
            node.audio.volume, node.audio.muted, node.audio.volumeChanges, node.audio.muteChanges
        ]).concat([fixture.preferredDefaultAudioSink?.nodeId, fixture.preferredDefaultAudioSource?.nodeId, fixture.sinkChanges, fixture.sourceChanges]));
    }

    function denied(action, message): void {
        const before = observedWrites();
        check(action() === false, message + " returns false");
        check(observedWrites() === before, message + " leaves backend unchanged");
    }

    function noOp(action, message): void {
        const before = observedWrites();
        check(action() === true, message + " returns true");
        check(observedWrites() === before, message + " leaves backend unchanged");
    }

    function run(): void {
        check(service.enabled === false && service.controlsEnabled === false && service.backend === null, "safe construction defaults");
        check(service.status === "disabled" && service.reason.length > 0, "explicit disabled state");
        check(!service.outputAvailable && !service.inputAvailable && !service.available, "disabled availability");
        check(service.sinks.length === 0 && service.sources.length === 0 && service.streams.length === 0, "disabled lists");
        check(service.sink === null && service.source === null, "disabled defaults");
        check(!service.cava.available && !service.beatTracker.available && service.cava.values.length === 0, "analysis capabilities unavailable");
        denied(() => service.setVolume(0.8), "disabled volume");
        denied(() => service.cycleNextAudioOutput(), "disabled cycle");
        close(service.getStreamVolume(null), 0, "null stream volume");
        check(!service.getStreamMuted(null) && service.getStreamName(null) === "Unknown", "null stream helpers");

        service.enabled = true;
        check(service.status === "initializing" && service.reason.length > 0, "backend loading state");
        service.backendError = "Fixture component initialization failed";
        check(service.status === "unavailable" && service.reason === service.backendError, "known initialization failure");
        service.backendError = "";
        service.backend = fixture;
        check(service.status === "unavailable" && !service.backendReady && service.reason.length > 0, "unready backend is honest");
        fixture.ready = true;
        check(service.status === "unavailable" && service.backendReady, "ready backend with no hardware");
        denied(() => service.setAudioSink(speaker), "missing hardware selection");
        fixture.ready = false;
        fixture.lastError = "Fixture backend initialization denied";
        check(service.reason === fixture.lastError && service.lastError === fixture.lastError, "native backend failure detail");
        fixture.lastError = "";
        fixture.ready = true;
        service.backend = { ready: false, error: "Fixture legacy backend error" };
        check(service.status === "unavailable" && service.reason === "Fixture legacy backend error", "optional backend error fallback");
        service.backend = fixture;

        const beforeArrival = observedWrites();
        fixture.nodes.values = [speaker, headset, microphone, stream, warming, noAudio, null];
        fixture.defaultAudioSink = speaker;
        fixture.defaultAudioSource = microphone;
        check(service.status === "ready" && service.ready && service.available, "devices arrive reactively");
        check(service.outputAvailable && service.inputAvailable, "both defaults available");
        check(service.sinks.length === 3 && service.sources.length === 1 && service.streams.length === 1, "node classification");
        check(service.sink === speaker && service.source === microphone, "native defaults observed");
        check(observedWrites() === beforeArrival, "arrival/default observation makes no writes");
        check(service.muted && service.sourceMuted, "initial mute read");
        close(service.volume, 0.4, "initial volume read");
        check(service.getStreamName(stream) === "Fixture player", "application name first");
        stream.properties = ({});
        check(service.getStreamName(stream) === "Stream description", "description fallback");
        stream.description = "";
        check(service.getStreamName(stream) === "stream-name", "name fallback");
        stream.name = "";
        check(service.getStreamName(stream) === "Unknown application", "empty stream name fallback");

        denied(() => service.setVolume(0.7), "read-only output volume");
        denied(() => service.setSourceVolume(0.7), "read-only input volume");
        denied(() => service.setMuted(false), "read-only output mute");
        denied(() => service.setSourceMuted(false), "read-only input mute");
        denied(() => service.setStreamVolume(stream, 0.7), "read-only stream volume");
        denied(() => service.setStreamMuted(stream, false), "read-only stream mute");
        denied(() => service.setAudioSink(headset), "read-only output selection");
        denied(() => service.setAudioSource(microphone), "read-only input selection");
        denied(() => service.cycleNextAudioOutput(), "read-only output cycle");

        speaker.audio.volume = 0.63;
        speaker.audio.muted = false;
        close(service.volume, 0.63, "external native volume signal");
        check(!service.muted, "external native mute signal");
        speaker.ready = false;
        check(!service.outputAvailable && service.inputAvailable && service.status === "ready", "per-node readiness signal");
        close(service.volume, 0, "unready output safely reads zero");
        speaker.ready = true;
        fixture.defaultAudioSink = headset;
        check(service.sink === headset, "external default output change");
        fixture.defaultAudioSink = speaker;
        fixture.defaultAudioSource = null;
        check(!service.inputAvailable && service.source === null && service.outputAvailable, "missing default input is independent");
        fixture.defaultAudioSource = microphone;

        service.controlsEnabled = true;
        check(service.outputControlsAvailable && service.inputControlsAvailable, "explicit node control capabilities");
        speaker.audio.controlAvailable = false;
        check(service.ready && service.outputAvailable && !service.outputControlsAvailable, "observation readiness does not imply control capability");
        denied(() => service.setVolume(0.8), "denied volume interface");
        denied(() => service.setMuted(false), "denied mute interface");
        speaker.audio.controlAvailable = true;
        const verifiedAudio = speaker.audio;
        speaker.audio = unverifiedAudio;
        check(service.outputAvailable && !service.outputControlsAvailable, "missing capability does not imply verified control");
        denied(() => service.setVolume(0.8), "older interface without explicit capability");
        speaker.audio = verifiedAudio;
        speaker.audio.stateAvailable = false;
        check(!service.outputAvailable && !service.outputControlsAvailable, "failed native read is unavailable");
        denied(() => service.setVolume(0.8), "failed state-read volume guard");
        speaker.audio.stateAvailable = true;
        speaker.audio.controlError = "Fixture SetMute access denied";
        check(!service.setVolume(0.8), "native mute failure stops volume request");
        check(service.reason.indexOf("Fixture SetMute access denied") >= 0, "native node error visible");
        speaker.audio.controlError = "";
        fixture.rejectSelection = true;
        check(!service.setAudioSink(headset) && service.sink === speaker, "failed routing preserves observed default");
        check(service.lastError === "Fixture routing denied", "routing failure visible");
        fixture.rejectSelection = false;
        fixture.preferredDefaultAudioSink = null;
        fixture.defaultAudioSink = speaker;
        fixture.defaultSelectionError = "";
        service.maxVolume = 1.8;
        check(service.setVolume(2) && !speaker.audio.muted, "explicit volume request unmutes");
        close(speaker.audio.volume, 1, "Windows upper bound");
        check(service.setSourceVolume(-0.5), "negative finite input request accepted");
        close(microphone.audio.volume, 0, "input lower bound");
        service.maxVolume = 0.6;
        check(service.setSourceVolume(0.9) && service.setStreamVolume(stream, 1.2), "input/stream requests accepted");
        close(microphone.audio.volume, 0.6, "configured input upper bound");
        close(stream.audio.volume, 0.6, "configured stream upper bound");
        check(service.setStreamVolume(stream, -1), "finite negative stream request accepted");
        close(stream.audio.volume, 0, "stream lower bound");
        service.maxVolume = -1;
        check(service.setVolume(0.5), "negative configured cap is safe");
        close(speaker.audio.volume, 0, "negative configured cap becomes zero");
        service.maxVolume = NaN;
        check(service.setVolume(2), "invalid configured cap falls back safely");
        close(speaker.audio.volume, 1, "invalid configured cap never exceeds one");
        service.maxVolume = 1;

        for (const value of [NaN, Infinity, -Infinity, undefined, null, true, "0.5", {}, []]) {
            denied(() => service.setVolume(value), "invalid output number " + String(value));
            denied(() => service.setSourceVolume(value), "invalid input number " + String(value));
            denied(() => service.setStreamVolume(stream, value), "invalid stream number " + String(value));
        }
        for (const value of [NaN, Infinity, -Infinity, null, true, "0.1", -0.1]) {
            denied(() => service.incrementVolume(value), "invalid output increment " + String(value));
            denied(() => service.decrementSourceVolume(value), "invalid input decrement " + String(value));
        }
        denied(() => service.setStreamMuted(stream, "false"), "non-boolean mute");
        denied(() => service.setStreamVolume(null, 0.2), "null volume node");
        denied(() => service.setStreamMuted(noAudio, true), "missing audio interface");
        denied(() => service.setStreamVolume(warming, 0.2), "unready node volume");
        denied(() => service.setAudioSink(warming), "unready node selection");
        denied(() => service.setAudioSink(microphone), "input cannot be selected as output");
        denied(() => service.setAudioSource(speaker), "output cannot be selected as input");
        denied(() => service.setAudioSink(stream), "stream cannot be selected as output");

        check(service.setVolume(0.5) && service.setSourceVolume(0.5), "prepare increments");
        check(service.setMuted(true) && service.setSourceMuted(true), "mute convenience setters");
        noOp(() => service.incrementVolume(0), "zero output increment");
        noOp(() => service.decrementVolume(0), "zero output decrement");
        noOp(() => service.incrementSourceVolume(0), "zero input increment");
        noOp(() => service.decrementSourceVolume(0), "zero input decrement");
        close(service.audioIncrement, 0.05, "Windows default is five percent");
        check(service.incrementVolume() && service.incrementSourceVolume(), "default increments");
        close(service.volume, 0.55, "default output increment is five percent");
        close(service.sourceVolume, 0.55, "default input increment is five percent");
        check(service.decrementVolume() && service.decrementSourceVolume(), "default decrements");
        close(service.volume, 0.5, "default output decrement is five percent");
        close(service.sourceVolume, 0.5, "default input decrement is five percent");
        service.audioIncrement = 0.1;
        check(service.incrementVolume() && service.decrementSourceVolume(), "omitted step uses configured increment");
        close(service.volume, 0.6, "configured output increment");
        close(service.sourceVolume, 0.4, "configured input decrement");
        check(service.decrementVolume(0.2) && service.incrementSourceVolume(0.3), "explicit increments");
        close(service.volume, 0.4, "explicit output decrement");
        close(service.sourceVolume, 0.7, "explicit input increment");
        service.audioIncrement = NaN;
        denied(() => service.incrementVolume(), "invalid configured increment");
        service.audioIncrement = 0.1;
        speaker.audio.volume = NaN;
        close(service.volume, 0, "invalid native volume reads safely");
        denied(() => service.incrementVolume(), "invalid native volume cannot be incremented");
        check(service.setVolume(0.4), "explicit finite volume repairs invalid fixture value");

        check(service.cycleNextAudioOutput() && fixture.preferredDefaultAudioSink === headset && service.sink === headset, "cycle selects next ready output");
        check(service.cycleNextAudioOutput() && fixture.preferredDefaultAudioSink === speaker, "cycle skips unready output and wraps");
        check(service.setAudioSource(microphone) && fixture.preferredDefaultAudioSource === microphone, "explicit input selection");
        check(service.setStreamMuted(stream, true) && service.getStreamMuted(stream), "stream mute helpers");
        check(service.setStreamVolume(stream, 0.35) && !service.getStreamMuted(stream), "stream volume unmutes");
        close(service.getStreamVolume(stream), 0.35, "stream volume helper");

        fixture.nodes.values = [headset, microphone, warming];
        check(service.sink === null && !service.outputAvailable && service.inputAvailable, "removed default cannot remain usable");
        check(service.streams.length === 0, "stream removal is reactive");
        denied(() => service.setStreamVolume(speaker, 0.8), "removed output volume");
        denied(() => service.setStreamMuted(stream, false), "removed stream mute");
        denied(() => service.setAudioSink(speaker), "removed output selection");
        close(service.getStreamVolume(stream), 0, "removed stream read");
        check(!service.getStreamMuted(stream) && service.getStreamName(stream) === "Unknown", "removed stream helpers safe");
        fixture.nodes.values = [replacement, headset, microphone];
        denied(() => service.setAudioSink(speaker), "reused node id does not revive stale object");
        check(service.setAudioSink(replacement) && service.sink === replacement, "replacement object accepted");
        // The fixture records preferred-device requests. Clear the recorded
        // request along with the default to simulate the native getter.
        fixture.preferredDefaultAudioSink = null;
        fixture.defaultAudioSink = null;
        check(service.cycleNextAudioOutput() && service.sink === replacement, "cycle with no default selects first output");

        service.backendError = "Fixture access denied";
        check(service.status === "unavailable" && service.reason === "Fixture access denied", "explicit denied fixture");
        check(!service.outputAvailable && !service.inputAvailable, "denied availability");
        denied(() => service.setStreamVolume(replacement, 0.8), "denied volume");
        denied(() => service.setAudioSource(microphone), "denied selection");
        service.backendError = "";
        fixture.ready = false;
        check(service.status === "unavailable" && service.sinks.length === 0 && service.sink === null, "backend becomes unready");
        denied(() => service.setStreamMuted(replacement, true), "unready backend mute");
        denied(() => service.setAudioSink(replacement), "unready backend selection");
        fixture.ready = true;
        service.enabled = false;
        check(service.status === "disabled" && !service.available && service.sinks.length === 0, "disable clears observed state");
        denied(() => service.incrementSourceVolume(), "disabled input increment");
        console.log("CAELESTIA_AUDIO_FIXTURE_PASS " + JSON.stringify({ assertions: assertions }));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_AUDIO_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
