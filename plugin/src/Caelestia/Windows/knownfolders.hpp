#pragma once

#include <qobject.h>
#include <qqmlintegration.h>

#include "knownfolderpaths.hpp"

namespace caelestia::shell::windows {

// The user folders Windows may redirect. Paths are exposed once here so QML
// never rebuilds them from USERPROFILE. Configured paths still take precedence
// at the call site (for example Paths.wallsdir over paths.wallpaperDir).
class KnownFolders: public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString pictures READ pictures CONSTANT)
    Q_PROPERTY(QString videos READ videos CONSTANT)
    Q_PROPERTY(QString desktop READ desktop CONSTANT)
    Q_PROPERTY(QString documents READ documents CONSTANT)
    Q_PROPERTY(QString downloads READ downloads CONSTANT)
    Q_PROPERTY(QString music READ music CONSTANT)
    Q_PROPERTY(QString programs READ programs CONSTANT)
    Q_PROPERTY(QString commonPrograms READ commonPrograms CONSTANT)

public:
    using QObject::QObject;

    QString pictures() const { return resolveKnownFolder(FOLDERID_Pictures); }
    QString videos() const { return resolveKnownFolder(FOLDERID_Videos); }
    QString desktop() const { return resolveKnownFolder(FOLDERID_Desktop); }
    QString documents() const { return resolveKnownFolder(FOLDERID_Documents); }
    QString downloads() const { return resolveKnownFolder(FOLDERID_Downloads); }
    QString music() const { return resolveKnownFolder(FOLDERID_Music); }
    QString programs() const { return resolveKnownFolder(FOLDERID_Programs); }
    QString commonPrograms() const { return resolveKnownFolder(FOLDERID_CommonPrograms); }
};

} // namespace caelestia::shell::windows
