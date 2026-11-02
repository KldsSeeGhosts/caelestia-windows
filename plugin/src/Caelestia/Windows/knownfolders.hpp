#pragma once

#include <functional>
#include <thread>

#include <qcoreapplication.h>
#include <qobject.h>
#include <qpointer.h>
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

    using ImageProbe = std::function<bool(const QString&)>;

    // Test seam: replaces the folder enumeration. Set it before probing.
    void setImageProbe(ImageProbe probe) { m_probe = std::move(probe); }

    // Normalise a path the way the Known Folders are normalised, so QML and
    // the plugin agree on drive and share roots.
    Q_INVOKABLE static QString normalizePath(const QString& path) { return normalizeFolderPath(path); }

    // Looks for wallpaper images in a folder on a worker thread and reports the
    // answer through imagesProbed on the GUI thread. The enumeration can stall
    // for a long time on an unavailable network share, so it never runs on the
    // GUI thread. The worker is detached on purpose: joining it at shutdown
    // would hold the exit of the shell for as long as the share keeps stalling,
    // and it touches only its own copies and a guarded pointer.
    Q_INVOKABLE void probeImages(const QString& path) {
        std::thread([self = QPointer<KnownFolders>(this), probe = m_probe, path] {
            const bool found = probe(path);
            if (auto* app = QCoreApplication::instance()) {
                QMetaObject::invokeMethod(
                    app,
                    [self, path, found] {
                        if (self)
                            emit self->imagesProbed(path, found);
                    },
                    Qt::QueuedConnection);
            }
        }).detach();
    }

signals:
    void imagesProbed(const QString& path, bool found);

private:
    ImageProbe m_probe = folderContainsImages;

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
