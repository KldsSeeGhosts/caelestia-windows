#pragma once

#include <qdiriterator.h>
#include <qfileinfo.h>
#include <qobject.h>
#include <qqmlintegration.h>

#include "knownfolderpaths.hpp"

namespace caelestia::shell::windows {

// The user folders Windows may redirect. Resolve them once at startup and keep
// the Q_PROPERTYs CONSTANT; a redirection changed while the shell runs takes
// effect after a restart. Configured paths still take precedence at the call
// site (for example Paths.wallsdir over paths.wallpaperDir).
class KnownFolders : public QObject {
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

    QString pictures() const { return m_pictures; }

    QString videos() const { return m_videos; }

    QString desktop() const { return m_desktop; }

    QString documents() const { return m_documents; }

    QString downloads() const { return m_downloads; }

    QString music() const { return m_music; }

    QString programs() const { return m_programs; }

    QString commonPrograms() const { return m_commonPrograms; }

    // The same image extensions the wallpaper scanner accepts. Extension
    // matching is case-insensitive on every platform, and the scan stops at
    // the first image.
    Q_INVOKABLE bool containsImages(const QString& path) const {
        if (path.isEmpty())
            return false;

        QDirIterator it(path, QDir::Files | QDir::NoDotAndDotDot);
        while (it.hasNext()) {
            const auto suffix = QFileInfo(it.next()).suffix().toLower();
            if (suffix == u"png" || suffix == u"jpg" || suffix == u"jpeg" || suffix == u"bmp" || suffix == u"webp")
                return true;
        }
        return false;
    }

private:
    const QString m_pictures = resolveKnownFolder(FOLDERID_Pictures);
    const QString m_videos = resolveKnownFolder(FOLDERID_Videos);
    const QString m_desktop = resolveKnownFolder(FOLDERID_Desktop);
    const QString m_documents = resolveKnownFolder(FOLDERID_Documents);
    const QString m_downloads = resolveKnownFolder(FOLDERID_Downloads);
    const QString m_music = resolveKnownFolder(FOLDERID_Music);
    const QString m_programs = resolveKnownFolder(FOLDERID_Programs);
    const QString m_commonPrograms = resolveKnownFolder(FOLDERID_CommonPrograms);
};

} // namespace caelestia::shell::windows
