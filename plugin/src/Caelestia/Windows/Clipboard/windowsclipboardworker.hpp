#pragma once

#include <memory>

#include <qobject.h>
#include <qstring.h>
#include <qvariant.h>

namespace caelestia::shell::windows {

// All Windows.ApplicationModel.DataTransfer.Clipboard work happens on this
// object's dedicated MTA worker thread. The frontend only receives plain
// values, so no WinRT call or clipboard read can block the GUI thread.
//
// Item maps exposed to QML: id, kind (text|image|other), text, imageUrl,
// timestamp, timestampLabel, formats. Image previews are materialized on
// request and live under the profile cache directory passed by the frontend.
class WindowsClipboardWorker: public QObject {
    Q_OBJECT

public:
    explicit WindowsClipboardWorker(QString cacheDirectory, QObject* parent = nullptr);
    ~WindowsClipboardWorker() override;

    // Runs on the worker thread. Registers the static clipboard events.
    void begin();
    // Runs on the worker thread before its event loop stops.
    void end();

    // Thread-safe. Stops pending work and best-effort cancels the in-flight
    // history read. The facade calls it before its bounded thread wait, when
    // the worker thread may already be blocked inside a WinRT call.
    void requestStop();

public slots:
    void refresh();
    // Change events are only followed while the picker is open. A closed
    // picker never reads the clipboard history in the background.
    void setActive(bool active);
    void copyItem(const QString& id, bool paste);
    void removeItem(const QString& id);
    void clearHistory();
    void openItem(const QString& id);
    void requestImage(const QString& id);
    void setCacheDirectory(const QString& directory);

signals:
    void snapshotReady(const QVariantList& items, bool historyEnabled, const QString& status,
        const QString& error);
    void historyEnabledChanged(bool enabled);
    void imageReady(const QString& id, const QString& url);
    void operationFinished(const QString& operation, const QString& id, bool ok, const QString& error);
    void openUrl(const QString& url);

private:
    void performRefresh(bool eventDriven);
    void scheduleEventRefresh();
    void startHistoryRead(quint64 generation, bool eventDriven);
    void publishSnapshot(const QVariantList& items, bool enabled, const QString& status,
        const QString& error);
    void reconcilePreviews(bool startup);
    void removeOpenFiles();
    [[nodiscard]] QString openDirectory() const;
    [[nodiscard]] QString previewDirectory() const;
    [[nodiscard]] QString ensurePreview(const QString& id);
    void removePreview(const QString& id);
    void clearPreviews();

    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace caelestia::shell::windows
