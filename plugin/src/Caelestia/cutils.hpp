#pragma once

#include <qlist.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qquickitem.h>
#include <qvariant.h>

namespace caelestia::shell {

class CUtils : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString qtVersion READ qtVersion CONSTANT)

public:
    // No-op for declaring variable/expression dependencies in QML bindings
    Q_INVOKABLE static void dependency(const QVariant& value);

    Q_INVOKABLE void saveItem(
        QQuickItem* target, const QUrl& path, const QJSValue& onSaved = {}, const QJSValue& onFailed = {});
    Q_INVOKABLE void saveItem(QQuickItem* target, const QUrl& path, const QRect& rect, const QJSValue& onSaved = {},
        const QJSValue& onFailed = {});

    Q_INVOKABLE static bool copyFile(const QUrl& source, const QUrl& target, bool overwrite = true);
    Q_INVOKABLE static bool deleteFile(const QUrl& path);
    // Screenshot hand-over files, kept in the OS temp directory.
    // newCaptureTempPath() creates a new empty file
    // <QDir::tempPath()>/caelestia-clipboard-<uuid>.png exclusively (NewOnly) and
    // returns its path, or an empty string. removeCaptureTemp(path) deletes one
    // such file. It accepts only a path exactly equal to the temp directory plus
    // that name scheme, and it refuses anything else, including `..` paths, other
    // names, directories and reparse points. It returns whether it deleted the file.
    Q_INVOKABLE static QString newCaptureTempPath();
    Q_INVOKABLE static bool removeCaptureTemp(const QString& path);
    // Drag files, kept in the OS temp directory. A copy-only screenshot that is
    // dragged out offers its own file, which has a normal screenshot name.
    // newDragFile(name) creates a new directory <QDir::tempPath()>/caelestia-drag-<uuid>/
    // (it must not exist yet), puts the empty file `name` in it and returns the
    // file's path, or an empty string and nothing left behind. `name` is one file
    // name that ends in ".png" and has no separator or character that Windows
    // forbids. removeDragFile(path) deletes such a file and then its directory. It
    // accepts only a path exactly equal to the temp directory plus that scheme, and
    // refuses anything else: other paths, nested paths, reparse points, a directory
    // with any entry besides the file. It returns whether the directory is gone
    // afterwards, and false when it refused or could not delete.
    Q_INVOKABLE static QString newDragFile(const QString& fileName);
    Q_INVOKABLE static bool removeDragFile(const QString& path);

    // Drags the image file at `path` out of the shell, Windows only. It offers
    // the file (CF_HDROP) and the decoded image (PNG, CF_DIB), allows copy only
    // and shows `preview` (an Item that draws the image) under the pointer. The
    // call returns when the drag has ended, wherever it was dropped or whether
    // Esc cancelled it. It returns false when no drag ran: the path is not an
    // image file, another drag is running, or the platform is not Windows. It
    // never writes a file. Call it from a pointer handler while the left button
    // is down. The drag, its data and its picture belong to the call, not to this
    // object or any item: tearing down the QML engine while the drag runs cancels
    // the drag and frees nothing under it. Nothing touches this object, the item
    // or the file after the call returns, so it is safe if they are gone by then.
    Q_INVOKABLE bool startImageDrag(const QString& path, QQuickItem* preview = nullptr);
    // How far the pointer has to move, in device pixels, before a press becomes
    // a drag: { width, height }.
    Q_INVOKABLE static QSize dragDistance();

    Q_INVOKABLE static QString toLocalFile(const QUrl& url);

    Q_INVOKABLE static qreal clamp(qreal value, qreal min, qreal max);

    Q_INVOKABLE static QString enumToString(QObject* target, const QString& property, const QVariant& value = {});

    Q_INVOKABLE static QQuickItem* findChild(QQuickItem* root, const QString& name);
    Q_INVOKABLE static QList<QQuickItem*> findChildren(QQuickItem* root, const QString& name);
    Q_INVOKABLE static QList<QQuickItem*> findChildrenMatching(QQuickItem* root, const QString& pattern);

    [[nodiscard]] static QString version();
    [[nodiscard]] static QString qtVersion();
};

} // namespace caelestia::shell
