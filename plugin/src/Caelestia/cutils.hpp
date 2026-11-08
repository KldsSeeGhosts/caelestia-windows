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

    // Drags the image file at `path` out of the shell, Windows only. It offers
    // the file (CF_HDROP) and the decoded image (PNG, CF_DIB), allows copy only
    // and shows `preview` (an Item that draws the image) under the pointer. The
    // call returns when the drag has ended, wherever it was dropped or whether
    // Esc cancelled it. It returns false when no drag ran: the path is not an
    // image file, another drag is running, or the platform is not Windows. It
    // never writes a file. Call it from a pointer handler while the left button
    // is down.
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
