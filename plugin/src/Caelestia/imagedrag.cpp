#include "imagedrag.hpp"

#include <algorithm>

#include <qdrag.h>
#include <qfileinfo.h>
#include <qguiapplication.h>
#include <qimagereader.h>
#include <qloggingcategory.h>
#include <qstylehints.h>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

namespace {

Q_LOGGING_CATEGORY(lcImageDrag, "caelestia.imagedrag", QtInfoMsg)

constexpr int fallbackLongSide = 256;

} // namespace

namespace caelestia::shell::imagedrag {

std::unique_ptr<QMimeData> mimeData(const QString& path) {
    const QFileInfo info(path);
    if (path.isEmpty() || !info.isAbsolute() || !info.isFile()) {
        qCWarning(lcImageDrag) << "mimeData: not an absolute path to a file" << path;
        return {};
    }

    QImageReader reader(info.absoluteFilePath());
    reader.setAutoTransform(true);
    const auto image = reader.read();
    if (image.isNull()) {
        qCWarning(lcImageDrag) << "mimeData: cannot decode" << path << reader.errorString();
        return {};
    }

    auto data = std::make_unique<QMimeData>();
    data->setImageData(image);
    return data;
}

Preview preview(const QMimeData& data, const QSizeF& logical, qreal dpr) {
    const auto image = qvariant_cast<QImage>(data.imageData());
    if (image.isNull())
        return {};

    const auto scale = dpr > 0 ? dpr : 1.0;
    QSizeF target = logical;
    if (!(target.width() > 0) || !(target.height() > 0)) {
        target = QSizeF(image.size());
        const auto longSide = std::max(target.width(), target.height());
        if (longSide > fallbackLongSide)
            target *= fallbackLongSide / longSide;
    }

    // The thumbnail fits the image into a box with its aspect, so the preview
    // keeps that aspect too instead of stretching to the box.
    const auto physical = image.size().scaled(
        std::max(1, qRound(target.width() * scale)), std::max(1, qRound(target.height() * scale)),
        Qt::KeepAspectRatio);
    Preview result;
    result.pixmap = QPixmap::fromImage(image.scaled(physical, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    result.pixmap.setDevicePixelRatio(scale);
    result.hotSpot = QPoint(qRound(physical.width() / scale / 2), qRound(physical.height() / scale / 2));
    return result;
}

std::optional<Qt::DropAction> run(std::unique_ptr<QMimeData> data, const Preview& preview, QObject* source,
    const std::function<Qt::DropAction(QDrag&)>& exec) {
    // One drag at a time: the drag runs its own event loop, so a second press
    // could otherwise start inside it.
    static bool running = false;
    if (!data || !source || running)
        return std::nullopt;

    running = true;
    struct Reset {
        ~Reset() { running = false; }
    } reset;

    // The drag is allocated on the heap under a parent of its own. Qt requires a
    // parent (it is the drag's source), and `source` cannot be it: the drag runs a
    // nested event loop, and a shell reload can destroy `source` inside that loop,
    // which would delete the drag and its data under OLE. The owner is local to
    // this call, so no engine, QML or deferred deletion can reach it. The drag,
    // its mime data and its pixmap are freed here, after exec has returned.
    QObject owner;
    auto* drag = new QDrag(&owner);
    drag->setMimeData(data.release());
    if (!preview.pixmap.isNull()) {
        drag->setPixmap(preview.pixmap);
        drag->setHotSpot(preview.hotSpot);
    }

    // When `source` goes away mid-drag, its reload is under way: end the drag
    // rather than keep a modal loop running in a half-destroyed engine. Nothing
    // below uses `source` again.
    QObject::connect(source, &QObject::destroyed, drag, [] { QDrag::cancel(); });

    return exec ? exec(*drag) : drag->exec(Qt::CopyAction, Qt::CopyAction);
}

QSize dragDistance() {
#ifdef Q_OS_WIN
    return QSize(std::max(1, int(GetSystemMetrics(SM_CXDRAG))), std::max(1, int(GetSystemMetrics(SM_CYDRAG))));
#else
    const auto distance = std::max(1, QGuiApplication::styleHints()->startDragDistance());
    return QSize(distance, distance);
#endif
}

} // namespace caelestia::shell::imagedrag
