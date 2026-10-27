#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qthread.h>
#include <qtimer.h>
#include <qvariant.h>
#include <qt_windows.h>

namespace caelestia::shell::windows {

class WindowsClipboardWorker;

// QML facade over Windows' native clipboard history. The worker thread owns
// every Windows.ApplicationModel.DataTransfer.Clipboard call; this object
// keeps only presentation data, the paste choreography and focus return.
//
// Windows keeps its own rules: password-manager exclusions, pinned items,
// size limits and sync. The shell never enables clipboard history, never logs
// clipboard contents and never maintains a parallel capture store.
class WindowsClipboard: public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // The profile cache directory for preview images and opened text files.
    // Empty disables both; the shell never writes elsewhere.
    Q_PROPERTY(QString cacheDirectory READ cacheDirectory WRITE setCacheDirectory NOTIFY
            cacheDirectoryChanged)
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    Q_PROPERTY(bool historyEnabled READ historyEnabled NOTIFY historyEnabledChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit WindowsClipboard(QObject* parent = nullptr);
    ~WindowsClipboard() override;

    [[nodiscard]] QString cacheDirectory() const { return m_cacheDirectory; }
    void setCacheDirectory(const QString& directory);

    [[nodiscard]] QVariantList items() const { return m_items; }
    [[nodiscard]] bool historyEnabled() const { return m_historyEnabled; }
    [[nodiscard]] QString status() const { return m_status; }
    [[nodiscard]] QString lastError() const { return m_lastError; }

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void setActive(bool active);
    Q_INVOKABLE void copy(const QString& id);
    Q_INVOKABLE void paste(const QString& id);
    Q_INVOKABLE void remove(const QString& id);
    Q_INVOKABLE void clear();
    Q_INVOKABLE void openItem(const QString& id);
    Q_INVOKABLE void requestImage(const QString& id);
    Q_INVOKABLE void openSettings() const;

signals:
    void cacheDirectoryChanged();
    void itemsChanged();
    void historyEnabledChanged();
    void statusChanged();
    void lastErrorChanged();
    void imageReady(const QString& id, const QString& url);
    // The item is now the clipboard content. The picker closes itself and the
    // synthetic paste follows after the close animation and focus return.
    void pasteReady(const QString& id);
    void operationFailed(const QString& operation, const QString& message);
    void openUrl(const QString& url);

private:
    struct NativeWindow {
        HWND hwnd = nullptr;
        DWORD process = 0;
        DWORD thread = 0;
    };

    [[nodiscard]] static NativeWindow identify(HWND hwnd);
    [[nodiscard]] static bool valid(const NativeWindow& window);
    void sampleForeground();
    void attemptPaste();
    [[nodiscard]] bool sendPasteChord() const;
    void setStatus(const QString& status);
    void setLastError(const QString& error);

    QThread m_thread;
    WindowsClipboardWorker* m_worker = nullptr;
    QVariantList m_items;
    QString m_cacheDirectory;
    QString m_status = QStringLiteral("initializing");
    QString m_lastError;
    QString m_pendingPasteId;
    QTimer m_pasteTimer;
    QTimer m_foregroundTimer;
    NativeWindow m_external;
    bool m_historyEnabled = false;
    bool m_pasteFocusRetried = false;
};

} // namespace caelestia::shell::windows
