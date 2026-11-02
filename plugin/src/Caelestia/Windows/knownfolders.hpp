#pragma once

#include <functional>
#include <memory>
#include <mutex>
#include <system_error>
#include <thread>
#include <vector>

#include <qcoreapplication.h>
#include <qhash.h>
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
    explicit KnownFolders(QObject* parent = nullptr)
        : QObject(parent) {
        // The delivery receiver lives and dies with this object on the GUI
        // thread; events still queued for it are dropped when it is destroyed.
        m_bridge->receiver = new QObject(this);
        if (auto* app = QCoreApplication::instance()) {
            // The backend deletes the application before it ends the process,
            // so stop delivering as soon as shutdown begins.
            connect(app, &QCoreApplication::aboutToQuit, this, [bridge = m_bridge] { bridge->close(); });
        }
    }

    ~KnownFolders() override { m_bridge->close(); }

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
    // GUI thread, and a request for a folder that is already being probed joins
    // that probe (process-wide, ignoring case and trailing separators), so
    // repeated requests against a hung share cannot pile up threads.
    //
    // The worker is detached on purpose: joining it at shutdown would hold the
    // exit of the shell for as long as the share keeps stalling. It reaches the
    // GUI thread only through the delivery bridge below.
    Q_INVOKABLE void probeImages(const QString& path) {
        const auto key = normalizeFolderPath(path).toLower();
        auto& registry = inflight();
        {
            std::lock_guard lock(registry.mutex);
            const auto pending = registry.waiters.find(key);
            const bool join = pending != registry.waiters.end();
            registry.waiters[key].push_back({ m_bridge, this, path });
            if (join)
                return;
        }

        try {
            std::thread([key, path, probe = m_probe] {
                const bool found = probe(path);

                std::vector<Waiter> waiters;
                {
                    auto& registry = inflight();
                    std::lock_guard lock(registry.mutex);
                    waiters = std::move(registry.waiters[key]);
                    registry.waiters.remove(key);
                }
                for (const auto& waiter : waiters)
                    deliver(waiter, found);
            }).detach();
        } catch (const std::system_error&) {
            // No thread could be started: forget the request so a later one retries.
            std::lock_guard lock(registry.mutex);
            registry.waiters.remove(key);
        }
    }

signals:
    void imagesProbed(const QString& path, bool found);

private:
    // Joint ownership of the hand-off between workers and the GUI thread. The
    // receiver is touched only under the mutex, and close() clears it before
    // the receiver is destroyed, so a worker never posts to a dead object. A
    // close waits only for a post in progress, never for an enumeration.
    struct Bridge {
        std::mutex mutex;
        QObject* receiver = nullptr;

        void close() {
            std::lock_guard lock(mutex);
            receiver = nullptr;
        }
    };

    struct Waiter {
        std::shared_ptr<Bridge> bridge;
        KnownFolders* owner; // valid whenever the bridge receiver is: it is the owner's child
        QString path;
    };

    struct Inflight {
        std::mutex mutex;
        QHash<QString, std::vector<Waiter>> waiters;
    };

    // Never destroyed: a detached worker may still be running at process exit.
    static Inflight& inflight() {
        static auto* registry = new Inflight;
        return *registry;
    }

    static void deliver(const Waiter& waiter, bool found) {
        std::lock_guard lock(waiter.bridge->mutex);
        if (!waiter.bridge->receiver)
            return;
        QMetaObject::invokeMethod(
            waiter.bridge->receiver,
            [owner = waiter.owner, path = waiter.path, found] { emit owner->imagesProbed(path, found); },
            Qt::QueuedConnection);
    }

    const std::shared_ptr<Bridge> m_bridge = std::make_shared<Bridge>();
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
