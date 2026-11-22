pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import Caelestia.Images

IconImage {
    id: root

    required property color colour

    asynchronous: true

    layer.enabled: true
    layer.effect: Colouriser {
        sourceColor: analyser.item?.dominantColour ?? Qt.color("transparent")
        colorizationColor: root.colour
    }

    layer.onEnabledChanged: {
        if (layer.enabled && status === Image.Ready)
            analyser.item?.requestUpdate();
    }

    onStatusChanged: {
        if (layer.enabled && status === Image.Ready)
            analyser.item?.requestUpdate();
    }

    // grabToImage() readbacks are only needed while this icon is actually
    // recoloured; an un-layered icon never instantiates the analyser.
    Loader {
        id: analyser

        active: root.layer.enabled
        sourceComponent: ImageAnalyser {
            sourceItem: root
        }
    }
}
