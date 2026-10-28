#pragma once

#include <memory>

#include <qobject.h>
#include <qstring.h>
#include <qvariant.h>

#include "clipboardstate.hpp"

namespace caelestia::shell::windows {

// All Windows.ApplicationModel.DataTransfer.Clipboard work happens on this
// object's dedicated MTA worker thread. The frontend only receives plain
// values, so no WinRT call or clipboard read can block the GUI thread.
//
// Item maps exposed to QML: id, kind (text|image|other), text, imageUrl,
// timestamp, timestampLabel, formats. Image previews and explicitly opened text
// files are materialized under this instance's own cache directory:
// <cacheRoot>/clipboard/<pid>-<random>.
class WindowsClipboardWorker: public QObject {
    Q_OBJECT

public:
    explicit WindowsClipboardWorker(std::shared_ptr<ClipboardSessionState> session,
        QObject* parent = nullptr);
    ~WindowsClipboardWorker() override;

    // Runs on the worker thread. Registers the static clipboard events.
    void begin();
    // Runs on the worker thread before its event loop stops.
    void end();

    // Runs on the worker thread: cancels and releases the in-flight history
    // read there, never under a GUI-thread mutex. The facade sets the shared
    // stop flag immediately and bounds the wait.
    void requestStop();

public slots:
    void refresh();
    // Change events are only followed while the picker is open. A closed
    // picker never reads the clipboard history in the background. The shared
    // session flag is updated by the facade, so this only manages the coalesced
    // event read on the worker thread.
    void setActive(bool active);
    void copyItem(const QString& id, bool paste);
    void removeItem(const QString& id);
    void clearHistory();
    void openItem(const QString& id);
    void requestImage(const QString& id);
    void setCacheRoot(const QString& directory);

signals:
    void snapshotReady(quint64 generation, const QVariantList& items, bool historyEnabled,
        const QString& status, const QString& error);
    void historyEnabledChanged(bool enabled);
    void imageReady(const QString& id, const QString& url);
    void operationFinished(const QString& operation, const QString& id, bool ok, const QString& error);
    void openUrl(const QString& url);

private:
    void performRefresh(bool eventDriven);
    void scheduleEventRefresh();
    void startHistoryRead(quint64 generation, bool eventDriven);
    void publishSnapshot(quint64 generation, const QVariantList& items, bool enabled,
        const QString& status, const QString& error);
    // `explicitOpen` reads are user actions: a picker close does not cancel them.
    [[nodiscard]] QString ensurePreview(const QString& id, bool explicitOpen);
    void removePreview(const QString& id);
    void evictPreviews(const QString& keep);
    void trackOpenedFile(const QString& path);
    void clearPreviews();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace caelestia::shell::windows
