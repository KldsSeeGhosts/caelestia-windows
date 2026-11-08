#include "cutils.hpp"

#include <qdatetime.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qloggingcategory.h>
#include <qmetaobject.h>
#include <qqmlengine.h>
#include <qquickitemgrabresult.h>
#include <qquickwindow.h>
#include <qregularexpression.h>
#include <qsavefile.h>
#include <qtconcurrentrun.h>

#include "util/metaenum.hpp"

namespace {

Q_LOGGING_CATEGORY(lcCUtils, "caelestia.cutils", QtInfoMsg)

} // namespace

namespace caelestia::shell {

void CUtils::dependency(const QVariant& value) {
    Q_UNUSED(value);
}

void CUtils::saveItem(QQuickItem* target, const QUrl& path, const QJSValue& onSaved, const QJSValue& onFailed) {
    this->saveItem(target, path, QRect(), onSaved, onFailed);
}

void CUtils::saveItem(
    QQuickItem* target, const QUrl& path, const QRect& rect, const QJSValue& onSaved, const QJSValue& onFailed) {
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

    QObject::connect(
        grabResult.data(), &QQuickItemGrabResult::ready, this,
        [grabResult, scaledRect, path, onSaved, onFailed, this] {
            QtConcurrent::run([image = grabResult->image(), scaledRect, file = path.toLocalFile()] {
                // Clip to the image: QImage::copy pads a rectangle that sticks out
                // with transparent pixels, and rounding at a fractional scale can
                // push the far edge a pixel past it. A crop with nothing inside
                // the image must fail; QImage::copy would return the whole image
                // for an empty rectangle, so a null image is used instead, which
                // fails to save.
                auto img = image;
                if (scaledRect.isValid()) {
                    const auto clip = scaledRect.intersected(image.rect());
                    img = clip.isEmpty() ? QImage() : image.copy(clip);
                }
                const auto parent = QFileInfo(file).absolutePath();
                return QDir().mkpath(parent) && img.save(file);
            }).then(this, [path, onSaved, onFailed](bool ok) {
                const auto* cb = ok ? &onSaved : &onFailed;
                if (!ok)
                    qCWarning(lcCUtils) << "saveItem: failed to save" << path;

                if (cb->isCallable())
                    cb->call({ path.toLocalFile() });
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

int CUtils::removeStale(const QUrl& directory, const QString& pattern, int olderThanSeconds) {
    if (!directory.isLocalFile() || pattern.isEmpty() || pattern.contains(QLatin1Char('/'))
        || pattern.contains(QLatin1Char('\\')) || olderThanSeconds < 0)
        return 0;

    const auto limit = QDateTime::currentDateTime().addSecs(-olderThanSeconds);
    int removed = 0;
    const auto files = QDir(directory.toLocalFile()).entryInfoList({ pattern }, QDir::Files | QDir::NoSymLinks);
    for (const auto& info : files) {
        if (info.lastModified() <= limit && QFile::remove(info.absoluteFilePath()))
            removed++;
    }
    return removed;
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
