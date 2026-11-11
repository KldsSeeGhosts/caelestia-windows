#pragma once

#include <functional>
#include <memory>
#include <optional>

#include <qimage.h>
#include <qmimedata.h>
#include <qpixmap.h>
#include <qpoint.h>
#include <qsize.h>
#include <qstring.h>

class QDrag;
class QObject;

// A copy-only drag of an image file out of the shell, for the screenshot
// thumbnail. CUtils::startImageDrag() is the QML entry point. The pieces are
// separate so the offered data and the preview can be tested without a window.
namespace caelestia::shell::imagedrag {

// Offers only the decoded image, which Qt's Windows converters deliver as
// PNG, CF_DIB and CF_DIBV5. No file, text, URL or Preferred DropEffect.
// Returns null unless
// `path` is an absolute path to an existing image that Qt can decode.
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
// is the object that asked for the drag and must not be null. It does not own
// anything: the drag, its data and its picture are owned by this call and freed
// after the drag loop has returned, whatever happens to `source` meanwhile. If
// `source` is destroyed while the drag runs, the drag is cancelled. Nothing
// touches `source` once the call has returned. Needs the GUI thread.
//
// `exec` replaces the call that blocks in the system's drag loop. Only tests
// pass it: a platform without a pointer (offscreen) never runs that loop, so a
// test uses it to run an event loop of its own while the drag exists.
std::optional<Qt::DropAction> run(std::unique_ptr<QMimeData> data, const Preview& preview, QObject* source,
    const std::function<Qt::DropAction(QDrag&)>& exec = {});

// The distance, in device pixels, that the pointer has to travel before a
// press becomes a drag. The system's setting on Windows (SM_CXDRAG and
// SM_CYDRAG), Qt's elsewhere.
QSize dragDistance();

} // namespace caelestia::shell::imagedrag
