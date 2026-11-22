#include "cutils.hpp"

#include <qcolorspace.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qhash.h>
#include <qloggingcategory.h>
#include <qmetaobject.h>
#include <qmutex.h>
#include <qpainter.h>
#include <qqmlengine.h>
#include <qquickimageprovider.h>
#include <qquickitemgrabresult.h>
#include <qquickwindow.h>
#include <qregularexpression.h>
#include <qsavefile.h>
#include <qtconcurrentrun.h>
#include <quuid.h>

#include "dragfile.hpp"
#include "imagedrag.hpp"
#include "util/metaenum.hpp"

namespace {

Q_LOGGING_CATEGORY(lcCUtils, "caelestia.cutils", QtInfoMsg)

using caelestia::shell::dragfile::isReparsePoint;

const QRegularExpression& captureTempName() {
    static const QRegularExpression name(QStringLiteral("^[0-9a-f]{32}\\.png\\z"));
    return name;
}

QRect cropBounds(const QImage& image, const QRect& scaledRect) {
    // Never pad with transparency when fractional scaling rounds the crop a
    // pixel past the grabbed buffer.
    return scaledRect.isValid() ? scaledRect.intersected(image.rect()) : image.rect();
}

QImage cropGrab(const QImage& image, const QRect& scaledRect) {
    const auto clip = cropBounds(image, scaledRect);
    if (clip.isEmpty())
        return {};
    return clip == image.rect() ? image : image.copy(clip);
}

QImage capturePreview(const QImage& image, const QRect& scaledRect, const QSize& bounds) {
    const auto clip = cropBounds(image, scaledRect);
    if (clip.isEmpty())
        return {};
    // Only retain a small preview in the image provider. The output file
    // still uses the original crop. Do not upscale small snips.
    const auto limit = bounds.boundedTo(QSize(768, 768));
    if (clip.width() <= limit.width() && clip.height() <= limit.height())
        return clip == image.rect() ? image : image.copy(clip);

    // Sample straight from the grabbed frame. The full crop copy belongs to
    // the disk write, and the preview doesn't need Qt's parallel area scaler.
    // Keep even extremely thin selections at least one pixel wide and tall.
    const auto size = clip.size().scaled(limit, Qt::KeepAspectRatio).expandedTo(QSize(1, 1));
    QImage preview(size, QImage::Format_ARGB32_Premultiplied);
    if (!preview.isNull()) {
        preview.setColorSpace(image.colorSpace());
        QPainter painter(&preview);
        painter.setCompositionMode(QPainter::CompositionMode_Source);
        painter.setRenderHint(QPainter::SmoothPixmapTransform);
        painter.drawImage(preview.rect(), image, clip);
    }
    return preview;
}

// A write can outlive its QML scope or even its engine. If nobody receives the
// finished file, remove exactly the reserved capture temp, never an export.
struct CaptureOutput {
    QString path;

    ~CaptureOutput() {
        if (!path.isEmpty())
            caelestia::shell::CUtils::removeCaptureTemp(path);
    }
};

} // namespace

namespace caelestia::shell {

class CapturePreviews {
public:
    QImage image(const QString& id) {
        const QMutexLocker lock(&this->mutex);
        return this->images.value(id);
    }

    QUrl add(QImage image) {
        const auto id = QUuid::createUuid().toString(QUuid::Id128);
        const QMutexLocker lock(&this->mutex);
        this->images.insert(id, std::move(image));
        return QUrl(QStringLiteral("image://caelestia-capture-preview/") + id);
    }

    void release(const QUrl& url) {
        if (url.scheme() != QStringLiteral("image") || url.host() != QStringLiteral("caelestia-capture-preview"))
            return;
        const QMutexLocker lock(&this->mutex);
        this->images.remove(url.path().mid(1));
    }

private:
    QMutex mutex;
    QHash<QString, QImage> images;
};

class CapturePreviewProvider : public QQuickImageProvider {
public:
    explicit CapturePreviewProvider(std::shared_ptr<CapturePreviews> previews)
        : QQuickImageProvider(QQuickImageProvider::Image), previews(std::move(previews)) {}

    QImage requestImage(const QString& id, QSize* size, const QSize&) override {
        const auto image = this->previews->image(id);
        if (size)
            *size = image.size();
        return image;
    }

private:
    std::shared_ptr<CapturePreviews> previews;
};

CUtils* CUtils::create(QQmlEngine* engine, QJSEngine*) {
    auto* utils = new CUtils;
    utils->capturePreviews = std::make_shared<CapturePreviews>();
    engine->addImageProvider(QStringLiteral("caelestia-capture-preview"), new CapturePreviewProvider(utils->capturePreviews));
    return utils;
}

void CUtils::releaseCapturePreview(const QUrl& preview) {
    if (this->capturePreviews)
        this->capturePreviews->release(preview);
}

void CUtils::dependency(const QVariant& value) {
    Q_UNUSED(value);
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path, const QJSValue& onSaved, const QJSValue& onFailed) {
    this->saveItem(target, path, QRect(), onSaved, onFailed);
}

void CUtils::saveItem(
    QQuickItem* target, const QUrl& path, const QRect& rect, const QJSValue& onSaved, const QJSValue& onFailed) {
    this->saveItemImpl(target, path, rect, {}, {}, onSaved, onFailed);
}

void CUtils::saveCaptureWithPreview(QQuickItem* target, const QUrl& path, const QRect& rect, const QSize& previewBounds,
    const QJSValue& onPreview, const QJSValue& onSaved, const QJSValue& onFailed) {
    this->saveItemImpl(target, path, rect, previewBounds, onPreview, onSaved, onFailed);
}

void CUtils::saveItemImpl(QQuickItem* target, const QUrl& path, const QRect& rect, const QSize& previewBounds,
    const QJSValue& onPreview, const QJSValue& onSaved, const QJSValue& onFailed) {
    // Every rejection reports through onFailed, so a caller that waits for a
    // result is never left waiting. The callback runs from the event loop, as it
    // does for a failure while saving.
    const auto reject = [this, &path, &onFailed](const char* reason) {
        qCWarning(lcCUtils) << "saveItem:" << reason;
        if (onFailed.isCallable()) {
            QMetaObject::invokeMethod(
                this, [onFailed, file = path.toLocalFile()] { onFailed.call({ file }); }, Qt::QueuedConnection);
        }
    };

    if (!target)
        return reject("a target is required");

    if (!path.isLocalFile())
        return reject("the path is not a local file");

    if (!target->window())
        return reject("unable to save a target without a window");

    auto scaledRect = rect;
    const auto scale = target->window()->devicePixelRatio();
    if (rect.isValid() && !qFuzzyCompare(scale + 1.0, 2.0)) {
        scaledRect =
            QRectF(rect.left() * scale, rect.top() * scale, rect.width() * scale, rect.height() * scale).toRect();
    }

    const auto grabResult = target->grabToImage();
    if (!grabResult)
        return reject("failed to grab the target");

    std::shared_ptr<CaptureOutput> output;
    if (onPreview.isCallable()) {
        output = std::make_shared<CaptureOutput>();
        output->path = path.toLocalFile();
    }
    QObject::connect(
        grabResult.data(), &QQuickItemGrabResult::ready, this,
        [grabResult, scaledRect, path, previewBounds, onPreview, onSaved, onFailed, output, this] {
            const auto finish = [path, onSaved, onFailed, output](bool ok) {
                const auto* cb = ok ? &onSaved : &onFailed;
                if (!ok)
                    qCWarning(lcCUtils) << "saveItem: failed to save" << path;

                if (cb->isCallable()) {
                    const auto result = cb->call({ path.toLocalFile() });
                    if (ok && output && result.isBool() && result.toBool())
                        output->path.clear();
                }
            };
            const auto write = [file = path.toLocalFile(), output](const QImage& img) {
                // Hold the reservation alive through the write even if the
                // completion callback is canceled when the engine goes away.
                const auto parent = QFileInfo(file).absolutePath();
                return QDir().mkpath(parent) && img.save(file);
            };
            if (!onPreview.isCallable() || previewBounds.isEmpty() || !this->capturePreviews) {
                QtConcurrent::run([image = grabResult->image(), scaledRect, write] {
                    return write(cropGrab(image, scaledRect));
                }).then(this, finish);
                return;
            }

            QtConcurrent::run([image = grabResult->image(), scaledRect, previewBounds] {
                return std::pair(image, capturePreview(image, scaledRect, previewBounds));
            }).then(this, [this, scaledRect, onPreview, write, finish](std::pair<QImage, QImage> result) {
                if (!result.second.isNull()) {
                    const auto url = this->capturePreviews->add(std::move(result.second));
                    const auto accepted = onPreview.call({ url.toString() });
                    if (!accepted.isBool() || !accepted.toBool())
                        this->releaseCapturePreview(url);
                }
                QtConcurrent::run([image = std::move(result.first), scaledRect, write] {
                    return write(cropGrab(image, scaledRect));
                }).then(this, finish);
            });
        },
        Qt::SingleShotConnection);
}

bool CUtils::copyFile(const QUrl& source, const QUrl& target, bool overwrite) {
    if (!source.isLocalFile()) {
        qCWarning(lcCUtils) << "copyFile: source" << source << "is not a local file";
        return false;
    }
    if (!target.isLocalFile()) {
        qCWarning(lcCUtils) << "copyFile: target" << target << "is not a local file";
        return false;
    }

    const auto src = source.toLocalFile();
    const auto dst = target.toLocalFile();

    if (!overwrite || !QFile::exists(dst))
        return QFile::copy(src, dst);

    // Windows: write to a temp sibling and atomically replace via QSaveFile so a failed overwrite leaves the target intact
    QFile in(src);
    if (!in.open(QIODevice::ReadOnly)) {
        qCWarning(lcCUtils) << "copyFile: failed to open source" << src;
        return false;
    }

    QSaveFile out(dst);
    if (!out.open(QIODevice::WriteOnly)) {
        qCWarning(lcCUtils) << "copyFile: failed to open target" << dst << out.errorString();
        return false;
    }

    while (!in.atEnd()) {
        const auto chunk = in.read(1 << 16);
        if (chunk.isEmpty() || out.write(chunk) != chunk.size()) {
            qCWarning(lcCUtils) << "copyFile: failed to copy to" << dst;
            out.cancelWriting();
            return false;
        }
    }

    if (!out.commit()) {
        qCWarning(lcCUtils) << "copyFile: failed to commit" << dst << out.errorString();
        return false;
    }
    return true;
}

bool CUtils::deleteFile(const QUrl& path) {
    if (!path.isLocalFile()) {
        qCWarning(lcCUtils) << "deleteFile: path" << path << "is not a local file";
        return false;
    }

    return QFile::remove(path.toLocalFile());
}

QString CUtils::newCaptureTempPath() {
    // A random 128-bit name, created with NewOnly: it can never collide with a
    // file of another picker, another reload or another process.
    for (int attempt = 0; attempt < 4; attempt++) {
        const auto path = QDir::tempPath() + QStringLiteral("/caelestia-clipboard-")
            + QUuid::createUuid().toString(QUuid::Id128) + QStringLiteral(".png");
        QFile file(path);
        if (file.open(QIODevice::WriteOnly | QIODevice::NewOnly))
            return path;
    }

    qCWarning(lcCUtils) << "newCaptureTempPath: cannot create a hand-over file in the temp directory";
    return {};
}

bool CUtils::removeCaptureTemp(const QString& path) {
    const auto prefix = QDir::tempPath() + QStringLiteral("/caelestia-clipboard-");
    // Paths on Windows are case-insensitive; the name part below is lower case hex.
    if (!path.startsWith(prefix, Qt::CaseInsensitive)
        || !captureTempName().match(QStringView(path).mid(prefix.size())).hasMatch()) {
        qCWarning(lcCUtils) << "removeCaptureTemp: not a capture hand-over file path";
        return false;
    }

    const QFileInfo info(path);
    if (!info.isFile() || isReparsePoint(path)) {
        qCWarning(lcCUtils) << "removeCaptureTemp: not a regular file";
        return false;
    }

    return QFile::remove(path);
}

QString CUtils::newDragFile(const QString& fileName) {
    return dragfile::create(QDir::tempPath(), fileName);
}

bool CUtils::removeDragFile(const QString& path) {
    return dragfile::remove(QDir::tempPath(), path);
}

bool CUtils::startImageDrag(const QString& path, QQuickItem* preview) {
#ifdef Q_OS_WIN
    auto data = imagedrag::mimeData(path);
    if (!data) {
        qCWarning(lcCUtils) << "startImageDrag: cannot offer" << path;
        return false;
    }

    const auto scale = preview && preview->window() ? preview->window()->devicePixelRatio() : 1.0;
    const auto look = imagedrag::preview(
        *data, preview ? QSizeF(preview->width(), preview->height()) : QSizeF(), scale);
    return imagedrag::run(std::move(data), look, this).has_value();
#else
    Q_UNUSED(path);
    Q_UNUSED(preview);
    qCWarning(lcCUtils) << "startImageDrag: only supported on Windows";
    return false;
#endif
}

QSize CUtils::dragDistance() {
    return imagedrag::dragDistance();
}

QString CUtils::toLocalFile(const QUrl& url) {
    if (!url.isLocalFile()) {
        qCWarning(lcCUtils) << "toLocalFile: given url is not a local file" << url;
        return {};
    }

    return url.toLocalFile();
}

qreal CUtils::clamp(qreal value, qreal min, qreal max) {
    return qBound(min, value, max);
}

QString CUtils::enumToString(QObject* target, const QString& property, const QVariant& value) {
    if (!target) {
        qCWarning(lcCUtils) << "enumToString: a target is required";
        return {};
    }

    const auto* meta = target->metaObject();
    const auto index = meta->indexOfProperty(property.toUtf8().constData());
    if (index < 0) {
        qCWarning(lcCUtils) << "enumToString:" << target << "has no property" << property;
        return {};
    }

    const auto prop = meta->property(index);
    const auto metaEnum = prop.isEnumType() ? prop.enumerator() : util::metaEnumFor(prop.metaType());
    if (!metaEnum.isValid() || metaEnum.is64Bit()) {
        qCWarning(lcCUtils) << "enumToString: property" << property << "of" << target << "is not a supported enum";
        return {};
    }

    const auto val = value.isValid() ? value : prop.read(target);
    const auto* key = util::enumKeyFor(metaEnum, val);
    if (!key) {
        qCWarning(lcCUtils, "enumToString: no enumerator of %s::%s has the value %lld", metaEnum.scope(),
            metaEnum.name(), val.toLongLong());
        return {};
    }

    return QString::fromUtf8(key);
}

namespace {

// DFS over the visual item tree (childItems), returning the first descendant matching the predicate. Unlike
// QObject::findChild, this walks parentItem/childItems relationships so it traverses the QML visual hierarchy.
template <typename Predicate> QQuickItem* findChildDfs(QQuickItem* root, Predicate&& match) {
    const auto children = root->childItems();
    for (QQuickItem* const child : children) {
        if (match(child)) {
            return child;
        }
        if (QQuickItem* const found = findChildDfs(child, match)) {
            return found;
        }
    }
    return nullptr;
}

// DFS over the visual item tree, appending every descendant matching the predicate to out.
template <typename Predicate> void findChildrenDfs(QQuickItem* root, Predicate&& match, QList<QQuickItem*>& out) {
    const auto children = root->childItems();
    for (QQuickItem* const child : children) {
        if (match(child)) {
            out.append(child);
        }
        findChildrenDfs(child, match, out);
    }
}

} // namespace

QQuickItem* CUtils::findChild(QQuickItem* root, const QString& name) {
    if (!root) {
        return nullptr;
    }

    return findChildDfs(root, [&name](const QQuickItem* item) {
        return item->objectName() == name;
    });
}

QList<QQuickItem*> CUtils::findChildren(QQuickItem* root, const QString& name) {
    QList<QQuickItem*> children;
    if (root) {
        findChildrenDfs(
            root,
            [&name](const QQuickItem* item) {
                return item->objectName() == name;
            },
            children);
    }
    return children;
}

QList<QQuickItem*> CUtils::findChildrenMatching(QQuickItem* root, const QString& pattern) {
    QList<QQuickItem*> children;
    if (root) {
        const QRegularExpression re(pattern);
        findChildrenDfs(
            root,
            [&re](const QQuickItem* item) {
                return re.match(item->objectName()).hasMatch();
            },
            children);
    }
    return children;
}

#ifndef CAELESTIA_VERSION
#define CAELESTIA_VERSION ""
#endif

QString CUtils::version() {
    return QStringLiteral(CAELESTIA_VERSION);
}

QString CUtils::qtVersion() {
    return QStringLiteral(QT_VERSION_STR);
}

} // namespace caelestia::shell
