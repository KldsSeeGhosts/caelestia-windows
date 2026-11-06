import QtQuick
import qs.services

// Windows combined host wiring for the original OSD content. The audio rows
// are shown only when the audio control opt-in is active, because the original
// component hides its volume rows rather than rendering a disabled slider; the
// combined launcher never enables audio controls, so the OSD presents the
// brightness row read-only with the original disabled slider styling. The
// resync serial restores the displayed level after a refused drag.
OsdContent {
    audioControlsEnabled: Audio.controlsEnabled
    brightnessControlsEnabled: monitor ? monitor.interactive : false
    brightnessResyncSerial: monitor ? monitor.resyncSerial : 0
}
