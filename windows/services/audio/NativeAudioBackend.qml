import QtQuick
import Quickshell.Services.Pipewire

// Loaded by URL only after Audio.enabled. Native Pipewire owns enumeration and
// endpoint/session change callbacks and reports initialization, state-read and
// control failures. No native audio writes occur during construction.
QtObject {
    id: root

    readonly property QtObject backend: Pipewire
    readonly property QtObject _tracker: PwObjectTracker {
        // Match the original Audio tracker coverage, including defaults during
        // a model update. The pinned Windows tracker only observes destruction;
        // it starts no polling, peak monitor, loopback capture, or visualization.
        objects: [root.backend.defaultAudioSink, root.backend.defaultAudioSource, ...root.backend.nodes.values].filter(node => node)
    }
}
