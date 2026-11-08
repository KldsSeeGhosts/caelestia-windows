#pragma once

#include <memory>
#include <optional>

#include <qimage.h>
#include <qmimedata.h>
#include <qpixmap.h>
#include <qpoint.h>
#include <qsize.h>
#include <qstring.h>

class QObject;

// A copy-only drag of an image file out of the shell, for the screenshot
// thumbnail. CUtils::startImageDrag() is the QML entry point. The pieces are
// separate so the offered data and the preview can be tested without a window.
namespace caelestia::shell::imagedrag {

// What the drag offers for the image file at `path`: the file itself (a
// file URL, which Windows delivers as CF_HDROP) and the decoded image (which
// Qt's Windows converters deliver as PNG, CF_DIB and CF_DIBV5). On Windows it
// also sets "Preferred DropEffect" to copy. Returns null unless `path` is an
// absolute path to an existing image that Qt can decode.
std::unique_ptr<QMimeData> mimeData(const QString& path);

struct Preview {
    QPixmap pixmap;
    // In logical pixels from the top left of the pixmap.
    QPoint hotSpot;
};

// The picture that follows the pointer. `logical` is the size the thumbnail
// draws the image at, in logical pixels, and `dpr` is its window's device pixel
// ratio. The picture keeps the image's aspect, so it covers the thumbnail's
// image exactly. An empty `logical` falls back to the image's own size, at most
// 256 logical pixels on the long side. The hot spot is the centre.
Preview preview(const QMimeData& data, const QSizeF& logical, qreal dpr);

// Runs the drag and returns once the pointer is released or Esc cancels it.
// Copy is the only action offered. Returns the action the target chose
// (Qt::IgnoreAction when dropped nowhere or cancelled), or nothing when no drag
// ran: no data, or another drag from this function is still running. `source`
// is the object Qt reports as the drag's source and must not be null. Needs the
// GUI thread.
std::optional<Qt::DropAction> run(
    std::unique_ptr<QMimeData> data, const Preview& preview, QObject* source);

// The distance, in device pixels, that the pointer has to travel before a
// press becomes a drag. The system's setting on Windows (SM_CXDRAG and
// SM_CYDRAG), Qt's elsewhere.
QSize dragDistance();

} // namespace caelestia::shell::imagedrag
