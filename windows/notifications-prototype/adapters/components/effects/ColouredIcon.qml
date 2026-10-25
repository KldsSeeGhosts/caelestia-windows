import QtQuick
import Quickshell.Widgets
import qs.components.effects

// Caelestia.Images is excluded from the portable Windows build, so the
// original dominant-colour analyser cannot load. This localized adapter keeps
// the original ColouredIcon name, IconImage source contract and Colouriser
// behaviour, but derives the source lightness from the requested colour instead
// of sampling the image. modules/notifications/Notification.qml still decides
// when layer.enabled applies.
IconImage {
    id: root

    required property color colour

    asynchronous: true

    layer.enabled: true
    layer.effect: Colouriser {
        sourceColor: root.colour
        colorizationColor: root.colour
    }
}
