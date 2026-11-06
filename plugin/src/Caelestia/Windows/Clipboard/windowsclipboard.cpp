#include "windowsclipboard.hpp"

#include <array>

#include <qcoreapplication.h>
#include <qdesktopservices.h>
#include <qloggingcategory.h>
#include <qmetaobject.h>
#include <qthread.h>
#include <qurl.h>

#include "windowsclipboardworker.hpp"

namespace caelestia::shell::windows {

namespace {

Q_LOGGING_CATEGORY(logClipboard, "caelestia.windows.clipboard")

// The picker's close animation is 100 ms and its focus guard restores the
// previous window 75 ms after closing. Inject after both have run.
constexpr int PASTE_INJECT_DELAY_MS = 240;
constexpr int PASTE_FOCUS_RETRY_MS = 80;
// Bounded waits: the destination must be verified foreground before any
// injection, and a physically held modifier must be released so the injected
// chord cannot become Win+Ctrl+V or release the user's own Ctrl.
constexpr int PASTE_FOCUS_TIMEOUT_MS = 700;
constexpr int PASTE_MODIFIER_TIMEOUT_MS = 1500;
constexpr int MODIFIER_POLL_MS = 40;
// A stalled WinRT call must not hang the GUI. The worker and its thread are
// handed to QThread::finished when this bound expires.
constexpr int WORKER_SHUTDOWN_WAIT_MS = 2500;

// Must match KeyboardHook::INJECTION_MARKER in the Windows Quickshell backend
// (src/windows/keyboard_hook.hpp). The shell's low-level keyboard hook ignores
// injected events carrying this marker, so the synthetic Ctrl+V cannot feed
// back into Caelestia's own hotkey or taskbar suppression hooks.
constexpr ULONG_PTR INJECTION_MARKER = 0x5153484B;

} // namespace

WindowsClipboard::WindowsClipboard(QObject* parent)
    : QObject(parent)
    , m_session(std::make_shared<ClipboardSessionState>()) {
    m_worker = new WindowsClipboardWorker(m_session);
    m_thread = new QThread();
    m_worker->moveToThread(m_thread);

    connect(m_thread, &QThread::started, m_worker, &WindowsClipboardWorker::begin);
    // One cleanup path, connected before start(): end() revokes WinRT events
    // and releases the apartment on the worker thread, then both objects are
    // deleted by deferred deletion. Nothing else deletes the worker or thread.
    connect(m_thread, &QThread::finished, m_worker, &WindowsClipboardWorker::end);
    connect(m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(m_thread, &QThread::finished, m_thread, &QObject::deleteLater);

    connect(m_worker, &WindowsClipboardWorker::snapshotReady, this,
        [this](quint64 generation, const QVariantList& items, bool enabled, const QString& status,
            const QString& error) {
            // The worker publishes a generation, but this signal may already be
            // queued when the picker closes. The GUI updates the shared session
            // synchronously on open/close, so a snapshot from a closed or older
            // session is rejected here even after a reopen.
            if (m_shuttingDown || m_session == nullptr || !m_session->acceptsSnapshot(generation))
                return;
            if (m_items != items) {
                m_items = items;
                emit itemsChanged();
            }
            if (m_historyEnabled != enabled) {
                m_historyEnabled = enabled;
                emit historyEnabledChanged();
            }
            setStatus(status);
            setLastError(error);
        });

    connect(m_worker, &WindowsClipboardWorker::historyEnabledChanged, this, [this](bool enabled) {
        if (m_historyEnabled == enabled)
            return;
        m_historyEnabled = enabled;
        emit historyEnabledChanged();
    });

    connect(m_worker, &WindowsClipboardWorker::imageReady, this,
        [this](const QString& id, const QString& url) {
            for (qsizetype i = 0; i < m_items.size(); ++i) {
                auto item = m_items.at(i).toMap();
                if (item.value(QStringLiteral("id")).toString() != id)
                    continue;
                item.insert(QStringLiteral("imageUrl"), url);
                m_items[i] = item;
                emit itemsChanged();
                break;
            }
            if (!url.isEmpty())
                emit imageReady(id, url);
        });

    connect(m_worker, &WindowsClipboardWorker::openUrl, this,
        [this](const QString& url) { emit openUrl(url); });

    connect(m_worker, &WindowsClipboardWorker::operationFinished, this,
        [this](const QString& operation, const QString& id, bool ok, const QString& error) {
            if (operation == QStringLiteral("paste")) {
                if (!ok) {
                    // The old clipboard content is still present; no paste may
                    // follow, and the pending destination is discarded.
                    failPaste(error, false);
                    return;
                }
                if (m_pendingPasteId != id)
                    return;
                emit pasteReady(id);
                m_pasteTimer.start(PASTE_INJECT_DELAY_MS);
                return;
            }
            if (!ok) {
                setLastError(error);
                emit operationFailed(operation, error);
            }
        });

    m_pasteTimer.setSingleShot(true);
    connect(&m_pasteTimer, &QTimer::timeout, this, &WindowsClipboard::attemptPaste);

    if (auto* app = QCoreApplication::instance()) {
        connect(
            app,
            &QCoreApplication::aboutToQuit,
            this,
            [this]() { shutdownWorker(); },
            Qt::DirectConnection);
    }

    m_thread->setObjectName(QStringLiteral("ClipboardHistory"));
    m_thread->start();
}

WindowsClipboard::~WindowsClipboard() {
    // shutdown() normally ran from the loader-owned wrapper's destruction.
    // This also covers process exit and any owner that forgot it.
    qCDebug(logClipboard) << "CAELESTIA_CLIPBOARD_NATIVE_DESTROYED";
    shutdownWorker();
}

void WindowsClipboard::shutdown() {
    if (m_shuttingDown)
        return;

    // The wrapper is about to be destroyed; let an observer (the smoke) see
    // the reset before the worker and retained history are gone. Do not emit
    // property notifications here: QML bindings on the dying wrapper must not
    // be re-evaluated.
    emit aboutToShutdown();
    m_items.clear();
    m_historyEnabled = false;
    m_lastError.clear();
    cancelPendingPaste();
    if (m_session != nullptr)
        m_session->deactivate();
    shutdownWorker();
}

void WindowsClipboard::setCacheRoot(const QString& directory) {
    if (m_cacheRoot == directory)
        return;
    m_cacheRoot = directory;
    if (m_worker != nullptr) {
        QMetaObject::invokeMethod(
            m_worker,
            [worker = m_worker, directory]() { worker->setCacheRoot(directory); },
            Qt::QueuedConnection);
    }
    emit cacheRootChanged();
}

void WindowsClipboard::refresh() {
    if (m_worker == nullptr || m_shuttingDown || m_session == nullptr)
        return;
    // Explicit refreshes obey the same session flag as event-driven reads. A
    // queued refresh that runs after the picker closed reads nothing.
    if (!m_session->active())
        return;
    // A newer request supersedes an in-flight per-item read immediately: the
    // bumped generation cancels it at its next poll, and the worker's own
    // performRefresh starts the new generation.
    (void)m_session->nextRead();
    setStatus(QStringLiteral("loading"));
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::refresh, Qt::QueuedConnection);
}

void WindowsClipboard::setActive(bool active) {
    if (m_worker == nullptr || m_shuttingDown || m_session == nullptr)
        return;

    if (active) {
        // A new picker session starts a new paste. Sample the destination
        // before this window becomes foreground and keep it immutable until
        // the paste completes or is abandoned.
        cancelPendingPaste();
        capturePasteDestination();
        m_session->activate();
    } else {
        // Publish the close immediately. The worker re-checks the shared flag
        // between blocking reads and before publishing, so a queued
        // setActive(false) cannot let a snapshot escape after close.
        m_session->deactivate();
    }

    QMetaObject::invokeMethod(
        m_worker,
        [worker = m_worker, active]() { worker->setActive(active); },
        Qt::QueuedConnection);
}

void WindowsClipboard::copy(const QString& id) {
    if (m_worker == nullptr || m_shuttingDown)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::copyItem, Qt::QueuedConnection, id,
        false);
}

void WindowsClipboard::paste(const QString& id) {
    if (m_worker == nullptr || m_shuttingDown)
        return;

    // The destination was captured when the picker opened. If it cannot be
    // identified, or is our own process, there is nothing safe to paste into.
    if (!m_pasteDestinationCaptured || !valid(m_pasteDestination)
        || m_pasteDestination.process == GetCurrentProcessId()) {
        failPaste(
            QStringLiteral(
                "Caelestia could not identify the window to paste into; copy the item instead."),
            false);
        return;
    }

    // paste() is called before the picker closes, so the destination captured
    // on open is still the only valid one. A previous request's timer is
    // superseded without discarding that destination.
    m_pasteTimer.stop();
    m_pendingPasteId = id;
    m_pasteWait.start();
    m_modifierWait.invalidate();
    m_focusRestoreRequested = false;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::copyItem, Qt::QueuedConnection, id,
        true);
}

void WindowsClipboard::remove(const QString& id) {
    if (m_worker == nullptr || m_shuttingDown)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::removeItem, Qt::QueuedConnection, id);
}

void WindowsClipboard::clear() {
    if (m_worker == nullptr || m_shuttingDown)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::clearHistory, Qt::QueuedConnection);
}

void WindowsClipboard::openItem(const QString& id) {
    if (m_worker == nullptr || m_shuttingDown)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::openItem, Qt::QueuedConnection, id);
}

void WindowsClipboard::requestImage(const QString& id) {
    if (m_worker == nullptr || m_shuttingDown)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::requestImage, Qt::QueuedConnection,
        id);
}

void WindowsClipboard::openSettings() const {
    // Read-only hand-off: Caelestia never turns clipboard history on itself.
    QDesktopServices::openUrl(QUrl(QStringLiteral("ms-settings:clipboard")));
}

WindowsClipboard::NativeWindow WindowsClipboard::identify(HWND hwnd) {
    NativeWindow identity;
    if (hwnd == nullptr || !IsWindow(hwnd) || !IsWindowVisible(hwnd))
        return identity;

    identity.thread = GetWindowThreadProcessId(hwnd, &identity.process);
    if (identity.thread != 0 && identity.process != 0)
        identity.hwnd = hwnd;
    return identity;
}

bool WindowsClipboard::valid(const NativeWindow& window) {
    if (window.hwnd == nullptr)
        return false;
    const auto current = identify(window.hwnd);
    return current.hwnd == window.hwnd && current.process == window.process
        && current.thread == window.thread;
}

bool WindowsClipboard::modifiersReleased() {
    // GetAsyncKeyState reads the physical modifier state; the injected chord
    // must not combine with a key the user is still holding.
    const auto down = [](int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; };
    return !down(VK_LWIN) && !down(VK_RWIN) && !down(VK_CONTROL) && !down(VK_LCONTROL)
        && !down(VK_RCONTROL) && !down(VK_MENU) && !down(VK_LMENU) && !down(VK_RMENU)
        && !down(VK_SHIFT) && !down(VK_LSHIFT) && !down(VK_RSHIFT);
}

void WindowsClipboard::capturePasteDestination() {
    m_pasteDestination = identify(GetForegroundWindow());
    m_pasteDestinationCaptured = m_pasteDestination.hwnd != nullptr
        && m_pasteDestination.process != GetCurrentProcessId();
    if (!m_pasteDestinationCaptured)
        m_pasteDestination = {};
}

void WindowsClipboard::cancelPendingPaste() {
    m_pasteTimer.stop();
    m_pendingPasteId.clear();
    m_pasteDestination = {};
    m_pasteDestinationCaptured = false;
    m_focusRestoreRequested = false;
    m_modifierWait.invalidate();
}

void WindowsClipboard::failPaste(const QString& message, bool copied) {
    cancelPendingPaste();
    setLastError(message);
    if (copied) {
        // SetHistoryItemAsContent succeeded, so the item is already on the
        // clipboard. Refusing to inject is not a copy failure: tell the user
        // how to finish the paste instead of cancelling invisibly.
        emit pasteDeferred(QStringLiteral("Copied. Press Ctrl+V to paste"));
        return;
    }
    emit operationFailed(QStringLiteral("paste"), message);
}

void WindowsClipboard::attemptPaste() {
    if (m_pendingPasteId.isEmpty())
        return;

    // The destination is immutable for this request. A changed identity (for
    // example a restarted application or a reused HWND) aborts the paste.
    if (!m_pasteDestinationCaptured || !valid(m_pasteDestination)) {
        failPaste(
            QStringLiteral("The window to paste into is no longer available; nothing was pasted."),
            true);
        return;
    }

    const auto destination = m_pasteDestination;
    const auto foreground = identify(GetForegroundWindow());

    if (foreground.hwnd != destination.hwnd) {
        // Another application took focus. Injecting now would paste into the
        // wrong window; only the shell's own process may be asked to restore
        // the captured destination, and only once.
        if (foreground.hwnd != nullptr && foreground.process != GetCurrentProcessId()) {
            failPaste(QStringLiteral("The foreground window changed; nothing was pasted."), true);
            return;
        }
        if (m_pasteWait.elapsed() >= PASTE_FOCUS_TIMEOUT_MS) {
            failPaste(QStringLiteral("The previous window did not regain focus; nothing was pasted."),
                true);
            return;
        }
        if (!m_focusRestoreRequested) {
            m_focusRestoreRequested = true;
            SetForegroundWindow(destination.hwnd);
        }
        m_pasteTimer.start(PASTE_FOCUS_RETRY_MS);
        return;
    }

    // Verified focus: do not inject while a modifier is still physically
    // down. Waiting is bounded and the paste is cancelled if the user keeps
    // holding the key.
    if (!modifiersReleased()) {
        if (!m_modifierWait.isValid())
            m_modifierWait.start();
        if (m_modifierWait.elapsed() >= PASTE_MODIFIER_TIMEOUT_MS) {
            failPaste(QStringLiteral("Modifier keys are still held; release them and paste again."),
                true);
            return;
        }
        m_pasteTimer.start(MODIFIER_POLL_MS);
        return;
    }

    // The user may have switched applications while the modifiers were held.
    if (identify(GetForegroundWindow()).hwnd != destination.hwnd) {
        failPaste(QStringLiteral("The foreground window changed; nothing was pasted."), true);
        return;
    }

    if (!sendPasteChord())
        failPaste(QStringLiteral("Windows refused the synthetic paste input."), true);
    else
        cancelPendingPaste();
}

bool WindowsClipboard::sendPasteChord() const {
    const auto keyInput = [](WORD vk, bool up) {
        INPUT input {};
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = vk;
        input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
        input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        input.ki.dwExtraInfo = INJECTION_MARKER;
        return input;
    };

    // Every physical modifier was verified released above, so pressing and
    // releasing Ctrl here cannot logically release a key the user still holds.
    std::array<INPUT, 4> inputs {
        keyInput(VK_CONTROL, false),
        keyInput('V', false),
        keyInput('V', true),
        keyInput(VK_CONTROL, true),
    };
    return SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT))
        == static_cast<UINT>(inputs.size());
}

void WindowsClipboard::shutdownWorker() {
    if (m_shuttingDown)
        return;
    m_shuttingDown = true;

    cancelPendingPaste();

    if (m_session != nullptr) {
        // Immediate and non-blocking: the worker observes this flag even if it
        // is currently blocked inside a WinRT read.
        m_session->deactivate();
        m_session->requestStop();
    }

    if (m_worker == nullptr)
        return;

    auto* worker = m_worker;
    auto* thread = m_thread;
    m_worker = nullptr;
    m_thread = nullptr;

    // No callback may reach this object after it starts being destroyed.
    disconnect(worker, nullptr, this, nullptr);

    // WinRT cancellation and release belong to the worker thread. Queue the
    // request; the QThread::finished -> end() path performs the same cancel if
    // the event loop never processes this call.
    QMetaObject::invokeMethod(worker, &WindowsClipboardWorker::requestStop, Qt::QueuedConnection);

    if (thread == nullptr)
        return;

    thread->quit();
    if (thread->wait(WORKER_SHUTDOWN_WAIT_MS))
        return;

    // A WinRT call did not return. Leave the thread and worker to the single
    // QThread::finished -> deleteLater path connected before start(); no
    // second delete and no manual detach is needed. The shared session flag is
    // already stopping, so a late result cannot be published.
    qCWarning(logClipboard) << "Clipboard worker did not stop within" << WORKER_SHUTDOWN_WAIT_MS
                            << "ms; leaving it to finish and self-delete.";
}

void WindowsClipboard::setStatus(const QString& status) {
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

void WindowsClipboard::setLastError(const QString& error) {
    if (m_lastError == error)
        return;
    m_lastError = error;
    emit lastErrorChanged();
}

} // namespace caelestia::shell::windows
