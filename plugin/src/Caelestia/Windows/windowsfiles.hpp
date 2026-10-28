#pragma once

#include <qfileinfo.h>
#include <qobject.h>
#include <qqmlintegration.h>

namespace caelestia::shell::windows {

// One explicit file check, without enumerating or watching its directory.
class WindowsFiles : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    using QObject::QObject;
    Q_INVOKABLE bool isFile(const QString& path) const { return QFileInfo(path).isFile(); }
};

} // namespace caelestia::shell::windows
