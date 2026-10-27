#include "windowsclipboard.hpp"

#include <array>

#include <qcoreapplication.h>
#include <qdesktopservices.h>
#include <qloggingcategory.h>
#include <qmetaobject.h>
#include <qurl.h>

#include "windowsclipboardworker.hpp"

namespace caelestia::shell::windows {

namespace {

Q_LOGGING_CATEGORY(logClipboard, "caelestia.windows.clipboard")

// The picker's close animation is 100 ms and its focus guard restores the
// previous window 75 ms after closing. Inject after both have run.
constexpr int PASTE_INJECT_DELAY_MS = 240;
constexpr int PASTE_FOCUS_RETRY_MS = 80;
constexpr int FOREGROUND_POLL_MS = 250;

// Must match KeyboardHook::INJECTION_MARKER in the Windows Quickshell backend
// (src/windows/keyboard_hook.hpp). The shell's low-level keyboard hook ignores
// injected events carrying this marker, so the synthetic Ctrl+V cannot feed
// back into Caelestia's own hotkey or taskbar suppression hooks.
constexpr ULONG_PTR INJECTION_MARKER = 0x5153484B;

} // namespace

WindowsClipboard::WindowsClipboard(QObject* parent)
    : QObject(parent) {
    m_worker = new WindowsClipboardWorker(QString());
    m_worker->moveToThread(&m_thread);

    connect(&m_thread, &QThread::started, m_worker, &WindowsClipboardWorker::begin);
    connect(&m_thread, &QThread::finished, m_worker, &WindowsClipboardWorker::end);

    connect(m_worker, &WindowsClipboardWorker::snapshotReady, this,
        [this](const QVariantList& items, bool enabled, const QString& status, const QString& error) {
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
            emit imageReady(id, url);
        });

    connect(m_worker, &WindowsClipboardWorker::openUrl, this,
        [this](const QString& url) { emit openUrl(url); });

    connect(m_worker, &WindowsClipboardWorker::operationFinished, this,
        [this](const QString& operation, const QString& id, bool ok, const QString& error) {
            if (operation == QStringLiteral("paste")) {
                if (!ok) {
                    setLastError(error);
                    emit operationFailed(operation, error);
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

    m_foregroundTimer.setInterval(FOREGROUND_POLL_MS);
    connect(&m_foregroundTimer, &QTimer::timeout, this, &WindowsClipboard::sampleForeground);
    sampleForeground();
    m_foregroundTimer.start();

    if (auto* app = QCoreApplication::instance()) {
        connect(
            app,
            &QCoreApplication::aboutToQuit,
            this,
            [this]() {
                m_foregroundTimer.stop();
                m_pasteTimer.stop();
                m_thread.quit();
                if (!m_thread.wait(2000))
                    qCWarning(logClipboard) << "Clipboard worker thread was still busy at exit.";
            },
            Qt::DirectConnection);
    }

    m_thread.setObjectName(QStringLiteral("ClipboardHistory"));
    m_thread.start();
}

WindowsClipboard::~WindowsClipboard() {
    m_foregroundTimer.stop();
    m_pasteTimer.stop();
    m_thread.quit();
    m_thread.wait();
    delete m_worker;
    m_worker = nullptr;
}

void WindowsClipboard::setCacheDirectory(const QString& directory) {
    if (m_cacheDirectory == directory)
        return;
    m_cacheDirectory = directory;
    if (m_worker != nullptr) {
        QMetaObject::invokeMethod(
            m_worker,
            [worker = m_worker, directory]() { worker->setCacheDirectory(directory); },
            Qt::QueuedConnection);
    }
    emit cacheDirectoryChanged();
}

void WindowsClipboard::refresh() {
    if (m_worker == nullptr)
        return;
    setStatus(QStringLiteral("loading"));
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::refresh, Qt::QueuedConnection);
}

void WindowsClipboard::setActive(bool active) {
    if (m_worker == nullptr)
        return;
    QMetaObject::invokeMethod(
        m_worker,
        [worker = m_worker, active]() { worker->setActive(active); },
        Qt::QueuedConnection);
}

void WindowsClipboard::copy(const QString& id) {
    if (m_worker == nullptr)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::copyItem, Qt::QueuedConnection, id,
        false);
}

void WindowsClipboard::paste(const QString& id) {
    if (m_worker == nullptr)
        return;
    m_pendingPasteId = id;
    m_pasteFocusRetried = false;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::copyItem, Qt::QueuedConnection, id,
        true);
}

void WindowsClipboard::remove(const QString& id) {
    if (m_worker == nullptr)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::removeItem, Qt::QueuedConnection, id);
}

void WindowsClipboard::clear() {
    if (m_worker == nullptr)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::clearHistory, Qt::QueuedConnection);
}

void WindowsClipboard::openItem(const QString& id) {
    if (m_worker == nullptr)
        return;
    QMetaObject::invokeMethod(m_worker, &WindowsClipboardWorker::openItem, Qt::QueuedConnection, id);
}

void WindowsClipboard::requestImage(const QString& id) {
    if (m_worker == nullptr)
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

void WindowsClipboard::sampleForeground() {
    const auto foreground = identify(GetForegroundWindow());
    if (foreground.hwnd != nullptr && foreground.process != GetCurrentProcessId())
        m_external = foreground;
}

void WindowsClipboard::attemptPaste() {
    if (m_pendingPasteId.isEmpty())
        return;

    if (!m_pasteFocusRetried && valid(m_external)) {
        const auto foreground = identify(GetForegroundWindow());
        if (foreground.hwnd != nullptr && foreground.process == GetCurrentProcessId()) {
            // The picker should already be hidden and its focus guard should
            // have restored the previous window. If Windows still holds our
            // process foreground, make one bounded restore attempt.
            m_pasteFocusRetried = true;
            SetForegroundWindow(m_external.hwnd);
            m_pasteTimer.start(PASTE_FOCUS_RETRY_MS);
            return;
        }
    }

    if (!sendPasteChord()) {
        const auto error = QStringLiteral("Windows refused the synthetic paste input.");
        setLastError(error);
        emit operationFailed(QStringLiteral("paste"), error);
    }
    m_pendingPasteId.clear();
    m_pasteFocusRetried = false;
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

    std::array<INPUT, 4> inputs {
        keyInput(VK_CONTROL, false),
        keyInput('V', false),
        keyInput('V', true),
        keyInput(VK_CONTROL, true),
    };
    return SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT))
        == static_cast<UINT>(inputs.size());
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
