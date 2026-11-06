import QtQuick
import Caelestia.Windows.Audio as WindowsAudio

// Windows port. The original audio providers (Caelestia.Windows.Audio
// CavaProvider/BeatTracker) are real Service objects, so a native ServiceRef
// keeps upstream ref/unref lifetime for Audio.cava and Audio.beatTracker. The
// Windows dashboard facades (Cpu, Memory, Gpu, Storage, NetworkUsage) are
// declarative singletons with no lifetime, so their reference stays inert
// instead of failing the Service type check.
QtObject {
    id: root

    required property var service

    readonly property WindowsAudio.ServiceRef _nativeRef: WindowsAudio.ServiceRef {
        service: root.service && typeof root.service.ref === "function" ? root.service : null
    }
}
