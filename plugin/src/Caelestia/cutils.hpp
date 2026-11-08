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
    // Screenshot hand-over files. The capture folder is <state>/capture, resolved
    // here from CAELESTIA_STATE_DIR (or the user state folder); QML never names
    // the folder or a pattern. newCaptureTempPath() creates a new empty file
    // clipboard-<uuid>.png exclusively and returns its path, or an empty string.
    // removeStaleCaptureTemps() deletes regular files in the capture folder whose
    // names match that scheme and that are older than a minute. It does nothing
    // if the capture folder or the state folder is a junction or symlink. It
    // returns how many files it removed.
    Q_INVOKABLE static QString newCaptureTempPath();
    Q_INVOKABLE static int removeStaleCaptureTemps();

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
