import QtQuick
import qs.services

// Windows combined host wiring for the original audio popout. The original
// AudioPopoutContent.qml (staged under its adapted name) is instantiated by
// the original popouts Content.qml, which cannot pass the Windows staging
// hooks. This adapter applies exactly the read-only wiring the bounded audio
// prototype host uses: every control hook follows the facade's control
// availability, which is false whenever CAELESTIA_WINDOWS_AUDIO_CONTROLS is
// off, and the original settings button is not staged.
AudioPopoutContent {
    outputControlsEnabled: Audio.outputControlsAvailable
    outputSelectionEnabled: Audio.sinks.some(node => Audio.canControl(node))
    inputControlsEnabled: Audio.sources.some(node => Audio.canControl(node))
    volumeAvailable: Audio.outputAvailable
    nodeControlsAvailable: node => Audio.canControl(node)
    settingsEnabled: false
}
