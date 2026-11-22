import QtQuick
import Quickshell

// Corrects the physical size when Qt Quick can only grab to the nearest size
// representable by a whole logical width and height at the current scale.
Canvas {
    id: root

    required property var grab
    required property string path
    required property size pixels
    required property real dpr
    required property var complete
    property bool submitted
    // Canvas and Item.grabToImage normally use the same window DPR. Canvas
    // can also be forced to another backing scale by Qt's environment knob.
    readonly property real canvasDpr: {
        const override = Number(Quickshell.env("QT_CANVAS_OVERRIDE_DEVICEPIXELRATIO"));
        return Number.isFinite(override) && override > 0 ? override : dpr;
    }

    width: 1
    height: 1
    opacity: 0
    canvasSize: Qt.size(Math.ceil(pixels.width / canvasDpr), Math.ceil(pixels.height / canvasDpr))
    canvasWindow: Qt.rect(0, 0, canvasSize.width, canvasSize.height)

    onAvailableChanged: {
        if (available) {
            loadImage(grab.url);
            if (isImageLoaded(grab.url))
                requestPaint();
        }
    }
    onImageLoaded: requestPaint()
    onPaint: {
        if (submitted || !isImageLoaded(grab.url))
            return;
        submitted = true;
        const ctx = getContext("2d");
        // The cached grab is a QImage with a DPR. Qt's Canvas scales that
        // QImage to the drawImage size in pixels, then QPainter applies the
        // image DPR when drawing it. Dividing the size here as well would
        // shrink the image twice and leave transparent right/bottom padding.
        if (dpr !== canvasDpr)
            ctx.scale(dpr / canvasDpr, dpr / canvasDpr);
        ctx.drawImage(String(grab.url), 0, 0, pixels.width, pixels.height);
        // Canvas resolves a URL path. Give drive paths the leading slash of
        // file:///C:/... before saving the exact number of physical pixels.
        const ok = save(path.startsWith("/") ? path : "/" + path, pixels);
        Qt.callLater(complete, ok);
    }
}
