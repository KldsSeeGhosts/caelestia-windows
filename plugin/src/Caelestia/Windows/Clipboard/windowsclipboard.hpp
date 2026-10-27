#pragma once

#include <memory>

#include <qelapsedtimer.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qtimer.h>
#include <qvariant.h>
#include <qt_windows.h>

#include "clipboardstate.hpp"

class QThread;

namespace caelestia::shell::windows {

class WindowsClipboardWorker;

// QML facade over Windows' native clipboard history. The worker thread owns
// every Windows.ApplicationModel.DataTransfer.Clipboard call; this object
// keeps only presentation data, the paste choreography and focus return.
//
// This is a regular QML element owned by the loader (not a singleton): when
// windows.clipboard.enabled becomes false the wrapper item is destroyed, which
// stops the worker, cancels pending pastes and drops retained history.
//
// Windows keeps its own rules: password-manager exclusions, pinned items,
// size limits and sync. The shell never enables clipboard history, never logs
// clipboard contents and never maintains a parallel capture store.
class WindowsClipboard: public QObject {
    Q_OBJECT
    QML_ELEMENT

    // The profile cache root. The instance creates exactly one directory,
    // <cacheRoot>/clipboard/<pid>-<random>, for previews and opened text.
    // Empty or relative values create nothing; the shell never writes
    // elsewhere.
    Q_PROPERTY(QString cacheRoot READ cacheRoot WRITE setCacheRoot NOTIFY cacheRootChanged)
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)
    Q_PROPERTY(bool historyEnabled READ historyEnabled NOTIFY historyEnabledChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    explicit WindowsClipboard(QObject* parent = nullptr);
    ~WindowsClipboard() override;

    [[nodiscard]] QString cacheRoot() const { return m_cacheRoot; }
    void setCacheRoot(const QString& directory);

    [[nodiscard]] QVariantList items() const { return m_items; }
    [[nodiscard]] bool historyEnabled() const { return m_historyEnabled; }
    [[nodiscard]] QString status() const { return m_status; }
    [[nodiscard]] QString lastError() const { return m_lastError; }

    Q_INVOKABLE void refresh();
    // The picker open/close edge. Opening captures the immutable paste
    // destination from the currently focused external window. The shared
    // session flag is updated immediately on both edges, not through the queue.
    Q_INVOKABLE void setActive(bool active);
    Q_INVOKABLE void copy(const QString& id);
    Q_INVOKABLE void paste(const QString& id);
    Q_INVOKABLE void remove(const QString& id);
    Q_INVOKABLE void clear();
    Q_INVOKABLE void openItem(const QString& id);
    Q_INVOKABLE void requestImage(const QString& id);
    Q_INVOKABLE void openSettings() const;
    // Explicit reset used by the loader-owned wrapper when it is destroyed
    // (or when windows.clipboard.enabled becomes false): cancels a pending
    // paste, stops the worker, unsubscribes both events and clears all
    // retained history and cache ownership. Idempotent; later calls no-op.
    Q_INVOKABLE void shutdown();

signals:
    void cacheRootChanged();
    void itemsChanged();
    void historyEnabledChanged();
    void statusChanged();
    void lastErrorChanged();
    void imageReady(const QString& id, const QString& url);
    // The item is now the clipboard content. The picker closes itself and the
    // synthetic paste follows after the close animation and verified focus
    // return to the window captured when the picker opened.
    void pasteReady(const QString& id);
    // The item is already on the clipboard, but injecting Ctrl+V was refused
    // (focus/destination changed, modifiers still held, or SendInput failed).
    // The user gets an informational toast instead of a silent cancel.
    void pasteDeferred(const QString& message);
    void operationFailed(const QString& operation, const QString& message);
    void openUrl(const QString& url);
    // Emitted from shutdown(), before the worker is stopped. The loader-owned
    // wrapper calls shutdown() on destruction; the smoke uses this to prove
    // the native backend is reset, not only that Loader.item became null.
    void aboutToShutdown();

private:
    struct NativeWindow {
        HWND hwnd = nullptr;
        DWORD process = 0;
        DWORD thread = 0;
    };

    [[nodiscard]] static NativeWindow identify(HWND hwnd);
    [[nodiscard]] static bool valid(const NativeWindow& window);
    [[nodiscard]] static bool modifiersReleased();
    void capturePasteDestination();
    void cancelPendingPaste();
    void failPaste(const QString& message, bool copied);
    void attemptPaste();
    [[nodiscard]] bool sendPasteChord() const;
    void shutdownWorker();
    void setStatus(const QString& status);
    void setLastError(const QString& error);

    QThread* m_thread = nullptr;
    WindowsClipboardWorker* m_worker = nullptr;
    std::shared_ptr<ClipboardSessionState> m_session;
    QVariantList m_items;
    QString m_cacheRoot;
    QString m_status = QStringLiteral("initializing");
    QString m_lastError;
    // The immutable destination for the pending paste. It is sampled when the
    // picker opens, not when paste() is called (the picker is foreground
    // then), and never updated by background foreground sampling.
    NativeWindow m_pasteDestination;
    QString m_pendingPasteId;
    QElapsedTimer m_pasteWait;
    QElapsedTimer m_modifierWait;
    QTimer m_pasteTimer;
    bool m_historyEnabled = false;
    bool m_pasteDestinationCaptured = false;
    bool m_focusRestoreRequested = false;
    bool m_shuttingDown = false;
};

} // namespace caelestia::shell::windows
