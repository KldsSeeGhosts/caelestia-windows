#include "windowsclipboardworker.hpp"

#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include <qcryptographichash.h>
#include <qdatetime.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qlocale.h>
#include <qloggingcategory.h>
#include <qmetaobject.h>
#include <qmetatype.h>
#include <qrandom.h>
#include <qset.h>
#include <qstringlist.h>
#include <qtimer.h>
#include <qt_windows.h>
#include <qurl.h>

#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include "clipboardcache.hpp"
#include "clipboardlogic.hpp"

namespace caelestia::shell::windows {

namespace {

Q_LOGGING_CATEGORY(logClipboard, "caelestia.windows.clipboard")

using winrt::Windows::ApplicationModel::DataTransfer::Clipboard;
using winrt::Windows::ApplicationModel::DataTransfer::ClipboardHistoryItem;
using winrt::Windows::ApplicationModel::DataTransfer::ClipboardHistoryItemsResult;
using winrt::Windows::ApplicationModel::DataTransfer::ClipboardHistoryItemsResultStatus;
using winrt::Windows::ApplicationModel::DataTransfer::DataPackageView;
using winrt::Windows::ApplicationModel::DataTransfer::StandardDataFormats;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::Collections::IVectorView;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Storage::IStorageItem;
using winrt::Windows::Storage::Streams::DataReader;
using winrt::Windows::Storage::Streams::IRandomAccessStreamWithContentType;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

constexpr int EVENT_COALESCE_MS = 150;
// A clipboard image larger than this is not materialized for preview. The
// history entry itself is untouched and copy/paste still works.
constexpr quint64 MAX_PREVIEW_BYTES = 64ULL * 1024ULL * 1024ULL;
constexpr int MAX_ITEMS = 100;
constexpr qsizetype MAX_NAME_HEX = 16;
// Per-item WinRT reads are awaited in short slices so a provider that never
// completes cannot hold the worker, a newer request or shutdown. The total
// bound covers one history refresh; preview and open reads get their own.
constexpr int ITEM_READ_POLL_MS = 10;
constexpr int ITEM_READ_TOTAL_TIMEOUT_MS = 3000;
constexpr int ITEM_READ_TIMEOUT_MS = 3000;

enum class ItemReadStatus { Completed, Cancelled, TimedOut, Failed };

QString fromHString(const winrt::hstring& value) {
    return QString::fromWCharArray(value.c_str(), static_cast<qsizetype>(value.size()));
}

// WinRT's message() can contain provider-specific text. Logs and toasts only
// receive fixed operation copy plus the numeric HRESULT, never that text.
QString hresultCode(const winrt::hresult_error& error) {
    return QStringLiteral("0x%1").arg(
        static_cast<quint32>(error.code().value), 8, 16, QLatin1Char('0'));
}

QString operationError(const QString& operation, const winrt::hresult_error& error) {
    return QStringLiteral("Couldn't %1 (%2)").arg(operation, hresultCode(error));
}

QString unknownErrorText(const QString& context) {
    return QStringLiteral("Unknown error while %1.").arg(context);
}

QString timestampIso(const winrt::Windows::Foundation::DateTime& value) {
    const auto point = winrt::clock::to_sys(value);
    const auto millis
        = std::chrono::duration_cast<std::chrono::milliseconds>(point.time_since_epoch()).count();
    return QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(millis)).toString(Qt::ISODate);
}

QString timestampLabel(const winrt::Windows::Foundation::DateTime& value) {
    const auto point = winrt::clock::to_sys(value);
    const auto millis
        = std::chrono::duration_cast<std::chrono::milliseconds>(point.time_since_epoch()).count();
    return QLocale().toString(QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(millis)),
        QStringLiteral("dddd HH:mm"));
}

// Qt detects image formats from content, but a truthful extension keeps the
// cache directory inspectable and avoids claiming every stream is PNG.
QString extensionFor(const QByteArray& bytes) {
    if (bytes.size() >= 8 && bytes.startsWith(QByteArrayLiteral("\x89PNG\r\n\x1a\n")))
        return QStringLiteral("png");
    if (bytes.size() >= 3 && static_cast<quint8>(bytes.at(0)) == 0xFF
        && static_cast<quint8>(bytes.at(1)) == 0xD8 && static_cast<quint8>(bytes.at(2)) == 0xFF) {
        return QStringLiteral("jpg");
    }
    if (bytes.size() >= 6 && bytes.startsWith(QByteArrayLiteral("GIF8")))
        return QStringLiteral("gif");
    if (bytes.size() >= 2 && bytes.startsWith(QByteArrayLiteral("BM")))
        return QStringLiteral("bmp");
    if (bytes.size() >= 12 && bytes.startsWith(QByteArrayLiteral("RIFF"))
        && bytes.mid(8, 4) == QByteArrayLiteral("WEBP")) {
        return QStringLiteral("webp");
    }
    if (bytes.size() >= 4
        && (bytes.startsWith(QByteArrayLiteral("II*\0"))
            || bytes.startsWith(QByteArrayLiteral("MM\0*")))) {
        return QStringLiteral("tiff");
    }
    return QStringLiteral("bin");
}

// Awaits one WinRT operation on the worker thread without a blocking get().
// The operation is cancelled as soon as the caller's predicate turns true or
// the deadline expires. A refresh or preview read cancels on a closed picker, a
// newer generation or shutdown; an explicit open cancels on shutdown only. An
// operation that already completed is always used, so completion is checked
// before cancellation.
template <typename T>
[[nodiscard]] ItemReadStatus awaitItemRead(const IAsyncOperation<T>& operation,
    const std::function<bool()>& cancelled, ULONGLONG deadline, T& value) {
    for (;;) {
        AsyncStatus status = AsyncStatus::Started;
        try {
            status = operation.Status();
        } catch (const winrt::hresult_error&) {
            return ItemReadStatus::Failed;
        } catch (...) {
            return ItemReadStatus::Failed;
        }

        if (status == AsyncStatus::Completed) {
            try {
                value = operation.GetResults();
                return ItemReadStatus::Completed;
            } catch (const winrt::hresult_error&) {
                return ItemReadStatus::Failed;
            } catch (...) {
                return ItemReadStatus::Failed;
            }
        }
        if (status != AsyncStatus::Started)
            return ItemReadStatus::Failed;

        if (cancelled()) {
            try {
                operation.Cancel();
            } catch (const winrt::hresult_error&) {
            } catch (...) {
            }
            return ItemReadStatus::Cancelled;
        }

        if (GetTickCount64() >= deadline) {
            try {
                operation.Cancel();
            } catch (const winrt::hresult_error&) {
            } catch (...) {
            }
            return ItemReadStatus::TimedOut;
        }
        Sleep(ITEM_READ_POLL_MS);
    }
}

template <typename T, typename Starter>
[[nodiscard]] ItemReadStatus awaitItemStart(Starter&& start,
    const std::function<bool()>& cancelled, ULONGLONG deadline, T& value) {
    IAsyncOperation<T> operation {nullptr};
    try {
        operation = start();
    } catch (const winrt::hresult_error&) {
        return ItemReadStatus::Failed;
    } catch (...) {
        return ItemReadStatus::Failed;
    }
    if (!operation)
        return ItemReadStatus::Failed;
    return awaitItemRead(operation, cancelled, deadline, value);
}

[[nodiscard]] ItemReadStatus readText(const DataPackageView& content,
    const std::function<bool()>& cancelled, ULONGLONG deadline, QString& text) {
    winrt::hstring value;
    const auto status = awaitItemStart(
        [&content]() { return content.GetTextAsync(); }, cancelled, deadline, value);
    if (status == ItemReadStatus::Completed)
        text = fromHString(value);
    return status;
}

[[nodiscard]] ItemReadStatus readBitmap(const ClipboardHistoryItem& item,
    const std::function<bool()>& cancelled, ULONGLONG deadline, QByteArray& bytes) {
    bytes.clear();
    const auto content = item.Content();
    if (!content.Contains(StandardDataFormats::Bitmap()))
        return ItemReadStatus::Completed;

    RandomAccessStreamReference reference {nullptr};
    auto status = awaitItemStart(
        [&content]() { return content.GetBitmapAsync(); }, cancelled, deadline, reference);
    if (status != ItemReadStatus::Completed)
        return status;
    if (!reference)
        return ItemReadStatus::Completed;

    IRandomAccessStreamWithContentType stream {nullptr};
    status = awaitItemStart(
        [&reference]() { return reference.OpenReadAsync(); }, cancelled, deadline, stream);
    if (status != ItemReadStatus::Completed)
        return status;
    if (!stream)
        return ItemReadStatus::Completed;

    const auto size = stream.Size();
    if (size == 0 || size > MAX_PREVIEW_BYTES)
        return ItemReadStatus::Completed;

    DataReader reader(stream.GetInputStreamAt(0));
    uint32_t loaded = 0;
    status = awaitItemStart(
        [&reader, size]() { return reader.LoadAsync(static_cast<uint32_t>(size)); }, cancelled,
        deadline, loaded);
    if (status != ItemReadStatus::Completed)
        return status;
    if (static_cast<quint64>(loaded) != size)
        return ItemReadStatus::Completed;

    std::vector<uint8_t> storage(static_cast<size_t>(size));
    reader.ReadBytes(storage);
    bytes = QByteArray(reinterpret_cast<const char*>(storage.data()),
        static_cast<qsizetype>(storage.size()));
    return ItemReadStatus::Completed;
}

QString formatsOf(const DataPackageView& content) {
    QStringList formats;
    try {
        for (const auto& format: content.AvailableFormats()) {
            const auto name = fromHString(format);
            if (!name.isEmpty())
                formats.append(name);
            if (formats.size() >= 8)
                break;
        }
    } catch (const winrt::hresult_error&) {
        // Format enumeration is presentation only.
    } catch (...) {
    }
    return formats.join(QStringLiteral(", "));
}

// A sibling cache directory may only be deleted when its process is gone.
// ERROR_ACCESS_DENIED means the process exists but cannot be opened; treat
// that as live and never touch its directory.
bool processAlive(quint32 pid) {
    if (pid == 0)
        return false;
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (process == nullptr)
        return GetLastError() == ERROR_ACCESS_DENIED;
    DWORD exitCode = 0;
    const bool alive = GetExitCodeProcess(process, &exitCode) && exitCode == STILL_ACTIVE;
    CloseHandle(process);
    return alive;
}

} // namespace

struct WindowsClipboardWorker::Impl {
    // WinRT event handlers run on arbitrary callback threads and revocation
    // does not wait for in-flight callbacks. They only hold this bridge: the
    // worker marks it dead under the mutex before it is destroyed, so a late
    // callback can never touch a destroyed worker.
    struct EventBridge {
        std::mutex mutex;
        bool alive = true;
        WindowsClipboardWorker* worker = nullptr;
    };

    struct Item {
        ClipboardHistoryItem handle {nullptr};
        QString kind = QStringLiteral("other");
        QString text;
        QString timestamp;
        QString timestampLabel;
        QString formats;
    };

    std::shared_ptr<ClipboardSessionState> session;
    ClipboardCacheDirectory cache;
    QHash<QString, Item> items;
    // Windows returns the history newest first. QHash does not preserve that,
    // so the exposed list follows this explicit order.
    QStringList order;
    QHash<QString, QString> previewFiles;
    std::shared_ptr<EventBridge> bridge;
    winrt::event_token historyToken {};
    winrt::event_token enabledToken {};
    QTimer* coalesce = nullptr;
    bool apartment = false;
    bool running = false;
    bool eventPending = false;
    bool historyRegistered = false;
    bool enabledRegistered = false;
    bool historyEnabled = false;

    // The async history read and its cancellation belong to the worker
    // thread. The GUI never takes this mutex and never touches a WinRT object.
    std::mutex asyncMutex;
    IAsyncOperation<ClipboardHistoryItemsResult> historyOperation {nullptr};

    // The history result is applied on the worker thread only, but the method
    // lives here so the WinRT type never appears in the public header. As a
    // nested class it can reach the worker's private members.
    //
    // Every WinRT access (Status(), enumeration, item ids, timestamps and
    // content reads) is inside the try: an hresult_error becomes the error
    // snapshot instead of crossing the queued-call boundary.
    void applyHistory(WindowsClipboardWorker& worker, quint64 generation, bool eventDriven,
        const ClipboardHistoryItemsResult& result, bool ok, const QString& error) {
        if (!running || session->stopping())
            return;
        if (!session->accepts(generation))
            return;
        if (eventDriven && !session->active())
            return;

        QVariantList list;
        QString status = QStringLiteral("ready");
        QString failure = error;
        bool enabled = true;
        bool itemTimedOut = false;

        // A close, a newer generation or shutdown cancels the current per-item
        // read instead of waiting for a provider that may never answer.
        const auto cancelled = [this, generation]() {
            return !running || session->stopping() || !session->accepts(generation);
        };
        const auto readDeadline = GetTickCount64() + ITEM_READ_TOTAL_TIMEOUT_MS;

        try {
            if (!ok) {
                status = QStringLiteral("error");
            } else {
                const auto resultStatus = result.Status();
                if (resultStatus == ClipboardHistoryItemsResultStatus::ClipboardHistoryDisabled) {
                    status = QStringLiteral("disabled");
                    enabled = false;
                } else if (resultStatus == ClipboardHistoryItemsResultStatus::AccessDenied) {
                    status = QStringLiteral("denied");
                    failure = QStringLiteral("Windows refused access to clipboard history.");
                } else if (resultStatus != ClipboardHistoryItemsResultStatus::Success) {
                    status = QStringLiteral("error");
                    failure = QStringLiteral("Windows returned clipboard history status %1.")
                                  .arg(static_cast<int>(resultStatus));
                } else {
                    QHash<QString, Item> next;
                    QStringList nextOrder;
                    for (const auto& handle: result.Items()) {
                        // Re-check between per-item reads: the picker may have
                        // closed while a text or format read was waiting.
                        if (cancelled())
                            return;
                        if (next.size() >= static_cast<qsizetype>(MAX_ITEMS))
                            break;
                        const auto id = fromHString(handle.Id());
                        if (id.isEmpty() || next.contains(id))
                            continue;

                        Item item;
                        item.handle = handle;
                        item.timestamp = timestampIso(handle.Timestamp());
                        item.timestampLabel = timestampLabel(handle.Timestamp());

                        try {
                            const auto content = handle.Content();
                            item.formats = formatsOf(content);
                            if (content.Contains(StandardDataFormats::Text())) {
                                QString text;
                                const auto read = readText(content, cancelled, readDeadline, text);
                                if (read == ItemReadStatus::Cancelled)
                                    return;
                                if (read == ItemReadStatus::TimedOut) {
                                    itemTimedOut = true;
                                    break;
                                }
                                if (read == ItemReadStatus::Completed)
                                    item.text = text;
                            }
                            const bool hasBitmap = content.Contains(StandardDataFormats::Bitmap());
                            if (!item.text.trimmed().isEmpty())
                                item.kind = QStringLiteral("text");
                            else if (hasBitmap)
                                item.kind = QStringLiteral("image");
                        } catch (const winrt::hresult_error&) {
                            // Keep the entry; a format that cannot be read must
                            // not hide the rest of the history.
                            item.kind = QStringLiteral("other");
                            item.text.clear();
                        } catch (...) {
                            item.kind = QStringLiteral("other");
                            item.text.clear();
                        }
                        next.insert(id, item);
                        nextOrder.append(id);
                    }

                    if (itemTimedOut) {
                        // One stuck provider aborts the whole refresh instead
                        // of spending the bound on every remaining item.
                        status = QStringLiteral("error");
                        failure = QStringLiteral("Windows did not finish reading the clipboard history.");
                        list.clear();
                    } else {
                        // Previews that no longer belong to an item are deleted
                        // here. Opened text files stay until shutdown.
                        for (auto it = previewFiles.begin(); it != previewFiles.end();) {
                            if (next.contains(it.key())) {
                                ++it;
                            } else {
                                const auto path = it.value();
                                it = previewFiles.erase(it);
                                cache.removeFile(path);
                            }
                        }

                        items = std::move(next);
                        order = nextOrder;

                        for (const auto& id: order) {
                            const auto& item = items.value(id);
                            const auto previewPath = previewFiles.value(id);
                            QVariantMap values;
                            values.insert(QStringLiteral("id"), id);
                            values.insert(QStringLiteral("kind"), item.kind);
                            values.insert(QStringLiteral("text"), item.text);
                            values.insert(QStringLiteral("imageUrl"),
                                previewPath.isEmpty() ? QString()
                                                      : QUrl::fromLocalFile(previewPath).toString());
                            values.insert(QStringLiteral("timestamp"), item.timestamp);
                            values.insert(QStringLiteral("timestampLabel"), item.timestampLabel);
                            values.insert(QStringLiteral("formats"), item.formats);
                            list.append(values);
                        }
                    }
                }
            }
        } catch (const winrt::hresult_error& readError) {
            status = QStringLiteral("error");
            failure = operationError(QStringLiteral("read clipboard history"), readError);
            list.clear();
        } catch (...) {
            status = QStringLiteral("error");
            failure = unknownErrorText(QStringLiteral("reading clipboard history"));
            list.clear();
        }

        if (status != QStringLiteral("ready")) {
            items.clear();
            order.clear();
            worker.clearPreviews();
        }

        // The picker may have closed while the last item was being read or the
        // map was being built. Nothing is published after close.
        if (!running || session->stopping() || !session->accepts(generation))
            return;
        worker.publishSnapshot(generation, list, enabled, status, failure);
    }
};

WindowsClipboardWorker::WindowsClipboardWorker(
    std::shared_ptr<ClipboardSessionState> session, QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>()) {
    m_impl->session = std::move(session);
    if (!m_impl->session)
        m_impl->session = std::make_shared<ClipboardSessionState>();
}

WindowsClipboardWorker::~WindowsClipboardWorker() {
    // The facade joins the thread before the worker is deleted, or leaves both
    // to the single QThread::finished -> deleteLater path. In either case the
    // owning thread is no longer running here.
    try {
        if (m_impl->running)
            end();
    } catch (...) {
        // A destructor must not throw, even if a WinRT release does.
    }
}

void WindowsClipboardWorker::begin() {
    auto& impl = *m_impl;
    if (impl.running || impl.session->stopping())
        return;
    impl.running = true;

    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        impl.apartment = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote()
            << operationError(QStringLiteral("initialize the clipboard worker"), error);
    } catch (...) {
        qCWarning(logClipboard) << "init_apartment(multi_threaded) failed with an unknown error.";
    }

    impl.coalesce = new QTimer(this);
    impl.coalesce->setSingleShot(true);
    impl.coalesce->setInterval(EVENT_COALESCE_MS);
    connect(impl.coalesce, &QTimer::timeout, this, [this]() {
        auto& impl = *m_impl;
        if (!impl.running || impl.session->stopping() || !impl.session->active())
            return;
        if (!impl.eventPending || impl.coalesce == nullptr)
            return;
        impl.eventPending = false;
        performRefresh(true);
    });

    // Static event handlers run on WinRT callback threads. They hold the
    // shared bridge and never capture the worker directly.
    impl.bridge = std::make_shared<Impl::EventBridge>();
    impl.bridge->worker = this;
    const auto bridge = impl.bridge;
    const auto queueRefresh = [bridge](auto&&, auto&&) {
        try {
            const std::lock_guard lock(bridge->mutex);
            if (!bridge->alive || bridge->worker == nullptr)
                return;
            auto* worker = bridge->worker;
            QMetaObject::invokeMethod(
                worker,
                [bridge]() {
                    try {
                        const std::lock_guard guard(bridge->mutex);
                        if (!bridge->alive || bridge->worker == nullptr)
                            return;
                        bridge->worker->scheduleEventRefresh();
                    } catch (...) {
                        // Never let an exception cross the queued boundary.
                    }
                },
                Qt::QueuedConnection);
        } catch (...) {
            // The callback thread boundary must stay exception-free.
        }
    };

    // Each subscription is revoked independently: one failing must not leave
    // the other registered.
    try {
        impl.historyToken = Clipboard::HistoryChanged(queueRefresh);
        impl.historyRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote()
            << operationError(QStringLiteral("subscribe to clipboard history changes"), error);
    } catch (...) {
        qCWarning(logClipboard) << "Couldn't subscribe to clipboard history changes.";
    }
    try {
        impl.enabledToken = Clipboard::HistoryEnabledChanged(queueRefresh);
        impl.enabledRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote()
            << operationError(QStringLiteral("subscribe to clipboard history setting changes"), error);
    } catch (...) {
        qCWarning(logClipboard) << "Couldn't subscribe to clipboard history setting changes.";
    }
}

void WindowsClipboardWorker::end() {
    auto& impl = *m_impl;
    if (!impl.running)
        return;
    impl.running = false;

    requestStop();
    impl.eventPending = false;

    if (impl.coalesce != nullptr) {
        impl.coalesce->stop();
        delete impl.coalesce;
        impl.coalesce = nullptr;
    }

    // Detach the event handlers before the worker is destroyed. Revocation
    // does not guarantee that an in-flight callback has finished, so the
    // bridge is the only thing those callbacks may touch.
    if (impl.bridge != nullptr) {
        const std::lock_guard lock(impl.bridge->mutex);
        impl.bridge->alive = false;
        impl.bridge->worker = nullptr;
    }

    try {
        if (impl.historyRegistered)
            Clipboard::HistoryChanged(impl.historyToken);
    } catch (const winrt::hresult_error&) {
        // Shutdown must not depend on event unregistration succeeding.
    } catch (...) {
    }
    impl.historyRegistered = false;

    try {
        if (impl.enabledRegistered)
            Clipboard::HistoryEnabledChanged(impl.enabledToken);
    } catch (const winrt::hresult_error&) {
        // Shutdown must not depend on event unregistration succeeding.
    } catch (...) {
    }
    impl.enabledRegistered = false;

    impl.items.clear();
    impl.order.clear();
    impl.previewFiles.clear();
    // Per-instance ownership: removes only this instance's directory, and
    // nothing at all if no valid cache root was ever configured.
    if (!impl.cache.remove())
        qCWarning(logClipboard) << "Could not remove this session's clipboard cache directory.";

    if (impl.apartment) {
        try {
            winrt::uninit_apartment();
        } catch (const winrt::hresult_error&) {
            // The process is shutting down; there is nothing useful to do.
        } catch (...) {
        }
        impl.apartment = false;
    }
}

void WindowsClipboardWorker::requestStop() {
    auto& impl = *m_impl;
    impl.session->requestStop();
    const std::lock_guard lock(impl.asyncMutex);
    if (impl.historyOperation) {
        try {
            impl.historyOperation.Cancel();
        } catch (const winrt::hresult_error&) {
            // Best effort: the facade's bounded wait still applies.
        } catch (...) {
        }
        impl.historyOperation = nullptr;
    }
}

void WindowsClipboardWorker::setActive(bool active) {
    auto& impl = *m_impl;
    if (!impl.running || impl.session->stopping())
        return;

    // The shared session flag was already updated on the GUI thread. A closed
    // picker must not leave a coalesced read pending, and a new session starts
    // without an event from the previous one.
    Q_UNUSED(active)
    if (impl.coalesce != nullptr)
        impl.coalesce->stop();
    impl.eventPending = false;
}

void WindowsClipboardWorker::refresh() {
    auto& impl = *m_impl;
    if (!impl.running || impl.session->stopping() || !impl.session->active())
        return;
    performRefresh(false);
}

void WindowsClipboardWorker::scheduleEventRefresh() {
    auto& impl = *m_impl;
    if (!impl.running || impl.session->stopping() || !impl.session->active())
        return;
    impl.eventPending = true;
    if (impl.coalesce != nullptr)
        impl.coalesce->start();
}

void WindowsClipboardWorker::performRefresh(bool eventDriven) {
    auto& impl = *m_impl;
    if (!impl.running || impl.session->stopping() || !impl.session->active())
        return;

    // Every read starts a new generation; a completion that arrives after a
    // newer read or a picker close is not published.
    const auto generation = impl.session->nextRead();

    QString status = QStringLiteral("ready");
    QString error;
    bool enabled = false;

    try {
        enabled = Clipboard::IsHistoryEnabled();
    } catch (const winrt::hresult_error& failure) {
        status = QStringLiteral("error");
        error = operationError(QStringLiteral("read the clipboard history setting"), failure);
    } catch (...) {
        status = QStringLiteral("error");
        error = unknownErrorText(QStringLiteral("reading the clipboard history setting"));
    }

    if (!impl.session->accepts(generation))
        return;

    if (status == QStringLiteral("ready") && !enabled)
        status = QStringLiteral("disabled");

    if (status != QStringLiteral("ready")) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
        if (!impl.session->accepts(generation))
            return;
        publishSnapshot(generation, {}, enabled, status, error);
        return;
    }

    if (impl.historyEnabled != enabled) {
        impl.historyEnabled = enabled;
        emit historyEnabledChanged(enabled);
    }
    startHistoryRead(generation, eventDriven);
}

void WindowsClipboardWorker::startHistoryRead(quint64 generation, bool eventDriven) {
    auto& impl = *m_impl;
    if (!impl.session->accepts(generation))
        return;

    IAsyncOperation<ClipboardHistoryItemsResult> operation {nullptr};
    try {
        operation = Clipboard::GetHistoryItemsAsync();
    } catch (const winrt::hresult_error& failure) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
        if (impl.session->accepts(generation))
            publishSnapshot(generation, {}, true, QStringLiteral("error"),
                operationError(QStringLiteral("read clipboard history"), failure));
        return;
    } catch (...) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
        if (impl.session->accepts(generation)) {
            publishSnapshot(generation, {}, true, QStringLiteral("error"),
                unknownErrorText(QStringLiteral("starting the clipboard history read")));
        }
        return;
    }

    if (!operation) {
        if (impl.session->accepts(generation)) {
            publishSnapshot(generation, {}, true, QStringLiteral("error"),
                QStringLiteral("Windows did not start a clipboard history read."));
        }
        return;
    }

    {
        const std::lock_guard lock(impl.asyncMutex);
        if (impl.session->stopping() || !impl.session->accepts(generation)) {
            try {
                operation.Cancel();
            } catch (const winrt::hresult_error&) {
            } catch (...) {
            }
            return;
        }
        impl.historyOperation = operation;
    }

    const auto bridge = impl.bridge;
    if (bridge == nullptr)
        return;

    try {
        operation.Completed([bridge, generation, eventDriven](
                                const IAsyncOperation<ClipboardHistoryItemsResult>& sender,
                                AsyncStatus asyncStatus) {
            try {
                // Cancellation is expected during shutdown and has no result.
                if (asyncStatus == AsyncStatus::Canceled)
                    return;

                ClipboardHistoryItemsResult result {nullptr};
                QString error;
                bool ok = false;
                try {
                    result = sender.GetResults();
                    ok = result != nullptr;
                } catch (const winrt::hresult_error& failure) {
                    error = operationError(QStringLiteral("read clipboard history"), failure);
                } catch (...) {
                    error = unknownErrorText(QStringLiteral("completing the clipboard history read"));
                }

                // Post while holding the bridge lock. end() marks the bridge
                // dead under the same lock, so the worker cannot be destroyed
                // between the liveness check and the queued invocation.
                const std::lock_guard lock(bridge->mutex);
                if (!bridge->alive || bridge->worker == nullptr)
                    return;
                auto* worker = bridge->worker;
                QMetaObject::invokeMethod(
                    worker,
                    [bridge, generation, eventDriven, result, ok, error]() {
                        try {
                            WindowsClipboardWorker* target = nullptr;
                            {
                                const std::lock_guard guard(bridge->mutex);
                                if (!bridge->alive || bridge->worker == nullptr)
                                    return;
                                target = bridge->worker;
                            }
                            target->m_impl->applyHistory(
                                *target, generation, eventDriven, result, ok, error);
                        } catch (...) {
                            // No exception may cross the queued-call boundary.
                        }
                    },
                    Qt::QueuedConnection);
            } catch (...) {
                // WinRT callback threads must stay exception-free.
            }
        });
    } catch (const winrt::hresult_error& failure) {
        {
            const std::lock_guard lock(impl.asyncMutex);
            if (impl.historyOperation == operation)
                impl.historyOperation = nullptr;
        }
        if (impl.session->accepts(generation)) {
            publishSnapshot(generation, {}, true, QStringLiteral("error"),
                operationError(QStringLiteral("read clipboard history"), failure));
        }
    } catch (...) {
        {
            const std::lock_guard lock(impl.asyncMutex);
            if (impl.historyOperation == operation)
                impl.historyOperation = nullptr;
        }
        if (impl.session->accepts(generation)) {
            publishSnapshot(generation, {}, true, QStringLiteral("error"),
                unknownErrorText(QStringLiteral("waiting for the clipboard history read")));
        }
    }
}

void WindowsClipboardWorker::publishSnapshot(quint64 generation, const QVariantList& items,
    bool enabled, const QString& status, const QString& error) {
    if (!m_impl->running || m_impl->session->stopping() || !m_impl->session->active()
        || !m_impl->session->accepts(generation)) {
        return;
    }
    if (m_impl->historyEnabled != enabled) {
        m_impl->historyEnabled = enabled;
        emit historyEnabledChanged(enabled);
    }
    emit snapshotReady(generation, items, enabled, status, error);
}

QString WindowsClipboardWorker::ensurePreview(const QString& id, bool explicitOpen) {
    auto& impl = *m_impl;
    if (impl.previewFiles.contains(id))
        return impl.previewFiles.value(id);

    const auto found = impl.items.constFind(id);
    if (found == impl.items.constEnd())
        return {};
    if (found->kind != QStringLiteral("image"))
        return {};

    QString directoryError;
    if (!impl.cache.ensure(&directoryError)) {
        qCWarning(logClipboard).noquote() << directoryError;
        return {};
    }

    QByteArray bytes;
    ItemReadStatus readStatus = ItemReadStatus::Failed;
    // The picker's close() runs before an explicit open, so only shutdown (and
    // the read deadline) may cancel that one. A displayed preview also stops on
    // a close or a newer generation.
    const auto generation = impl.session->generation();
    try {
        readStatus = readBitmap(found->handle,
            [&impl, generation, explicitOpen]() { return impl.session->cancelsRead(generation, explicitOpen); },
            GetTickCount64() + ITEM_READ_TIMEOUT_MS, bytes);
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote()
            << operationError(QStringLiteral("read a clipboard image"), error);
        return {};
    } catch (...) {
        qCWarning(logClipboard) << "Couldn't read a clipboard image (unknown error).";
        return {};
    }
    if (readStatus == ItemReadStatus::Cancelled)
        return {};
    if (readStatus != ItemReadStatus::Completed) {
        qCWarning(logClipboard) << "Couldn't read a clipboard image (the read did not complete).";
        return {};
    }
    if (bytes.isEmpty())
        return {};

    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(bytes);

    // Re-verify immediately before the write: the directory could have been
    // replaced while the bitmap was being read.
    if (!impl.cache.ensure(&directoryError)) {
        qCWarning(logClipboard).noquote() << directoryError;
        return {};
    }

    const auto path =
        impl.cache.writeFreshFile(QString::fromLatin1(hash.result().toHex().left(MAX_NAME_HEX)), extensionFor(bytes), bytes);
    if (path.isEmpty()) {
        qCWarning(logClipboard) << "Could not write a clipboard preview file.";
        return {};
    }

    impl.previewFiles.insert(id, path);
    return path;
}

void WindowsClipboardWorker::removePreview(const QString& id) {
    const auto path = m_impl->previewFiles.take(id);
    if (!path.isEmpty())
        m_impl->cache.removeFile(path);
}

void WindowsClipboardWorker::clearPreviews() {
    for (const auto& path: m_impl->previewFiles)
        m_impl->cache.removeFile(path);
    m_impl->previewFiles.clear();
}

void WindowsClipboardWorker::setCacheRoot(const QString& directory) {
    auto& impl = *m_impl;
    if (impl.session->stopping() || impl.cache.configured())
        return;
    if (directory.isEmpty())
        return;
    if (!ClipboardCacheDirectory::validRoot(directory)) {
        qCWarning(logClipboard) << "Ignoring a relative or invalid clipboard cache root.";
        return;
    }
    if (!impl.cache.configure(
            directory, GetCurrentProcessId(), QRandomGenerator::global()->generate64())) {
        qCWarning(logClipboard) << "Could not configure the clipboard cache directory.";
        return;
    }

    QString error;
    if (!impl.cache.ensure(&error)) {
        qCWarning(logClipboard).noquote() << error;
        return;
    }

    const auto removed = ClipboardCacheDirectory::removeDeadSiblings(
        impl.cache.root(), impl.cache.name(), [](quint32 pid) { return processAlive(pid); });
    qCDebug(logClipboard) << "Clipboard cache ready; dead siblings removed" << removed;
}

void WindowsClipboardWorker::requestImage(const QString& id) {
    if (!m_impl->running || m_impl->session->stopping() || !m_impl->session->active())
        return;

    const auto path = ensurePreview(id, false);
    if (path.isEmpty()) {
        emit operationFinished(QStringLiteral("preview"), id, false,
            QStringLiteral("The image could not be read from clipboard history."));
        return;
    }
    emit imageReady(id, QUrl::fromLocalFile(path).toString());
}

void WindowsClipboardWorker::copyItem(const QString& id, bool paste) {
    if (!m_impl->running || m_impl->session->stopping())
        return;

    const auto operation = paste ? QStringLiteral("paste") : QStringLiteral("copy");
    const auto found = m_impl->items.constFind(id);
    if (found == m_impl->items.constEnd()) {
        emit operationFinished(operation, id, false,
            QStringLiteral("The clipboard item is no longer in the history."));
        return;
    }

    try {
        // Windows applies its own rules for the restored item; the shell never
        // writes a parallel clipboard format or history entry. A non-Success
        // status means the old clipboard content is still present, so it must
        // never be followed by a synthetic paste.
        const auto status = static_cast<int>(Clipboard::SetHistoryItemAsContent(found->handle));
        const auto result = clipboardSetContentResult(status);
        if (!result.ok) {
            emit operationFinished(operation, id, false, result.message);
            return;
        }
        emit operationFinished(operation, id, true, QString());
    } catch (const winrt::hresult_error& error) {
        const auto action = paste ? QStringLiteral("paste the clipboard item")
                                  : QStringLiteral("copy the clipboard item");
        emit operationFinished(operation, id, false, operationError(action, error));
    } catch (...) {
        emit operationFinished(operation, id, false,
            unknownErrorText(QStringLiteral("restoring the clipboard item")));
    }
}

void WindowsClipboardWorker::removeItem(const QString& id) {
    if (!m_impl->running || m_impl->session->stopping())
        return;

    const auto found = m_impl->items.find(id);
    if (found == m_impl->items.end()) {
        emit operationFinished(QStringLiteral("remove"), id, false,
            QStringLiteral("The clipboard item is no longer in the history."));
        return;
    }

    try {
        if (!Clipboard::DeleteItemFromHistory(found->handle)) {
            emit operationFinished(QStringLiteral("remove"), id, false,
                QStringLiteral("Windows did not delete the clipboard history item."));
            return;
        }
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(QStringLiteral("remove"), id, false,
            operationError(QStringLiteral("delete the clipboard history item"), error));
        return;
    } catch (...) {
        emit operationFinished(QStringLiteral("remove"), id, false,
            unknownErrorText(QStringLiteral("deleting the clipboard history item")));
        return;
    }

    removePreview(id);
    m_impl->items.erase(found);
    m_impl->order.removeAll(id);
    emit operationFinished(QStringLiteral("remove"), id, true, QString());
    performRefresh(false);
}

void WindowsClipboardWorker::clearHistory() {
    if (!m_impl->running || m_impl->session->stopping())
        return;

    try {
        // Windows owns what ClearHistory removes, including pinned items.
        if (!Clipboard::ClearHistory()) {
            emit operationFinished(QStringLiteral("clear"), QString(), false,
                QStringLiteral("Windows did not clear the clipboard history."));
            return;
        }
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(QStringLiteral("clear"), QString(), false,
            operationError(QStringLiteral("clear the clipboard history"), error));
        return;
    } catch (...) {
        emit operationFinished(QStringLiteral("clear"), QString(), false,
            unknownErrorText(QStringLiteral("clearing the clipboard history")));
        return;
    }

    clearPreviews();
    m_impl->items.clear();
    m_impl->order.clear();
    emit operationFinished(QStringLiteral("clear"), QString(), true, QString());
    performRefresh(false);
}

void WindowsClipboardWorker::openItem(const QString& id) {
    if (!m_impl->running || m_impl->session->stopping())
        return;

    const auto found = m_impl->items.constFind(id);
    if (found == m_impl->items.constEnd()) {
        emit operationFinished(QStringLiteral("open"), id, false,
            QStringLiteral("The clipboard item is no longer in the history."));
        return;
    }

    try {
        if (found->kind == QStringLiteral("image")) {
            const auto path = ensurePreview(id, true);
            if (path.isEmpty()) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("The image could not be read from clipboard history."));
                return;
            }
            emit openUrl(QUrl::fromLocalFile(path).toString());
            return;
        }

        if (found->kind == QStringLiteral("text")) {
            const auto text = found->text.trimmed();
            if (!text.isEmpty() && text.indexOf(QLatin1Char('\n')) < 0
                && text.indexOf(QLatin1Char('\r')) < 0) {
                if (text.startsWith(QStringLiteral("http://"), Qt::CaseInsensitive)
                    || text.startsWith(QStringLiteral("https://"), Qt::CaseInsensitive)) {
                    emit openUrl(text);
                    return;
                }
                if (text.startsWith(QStringLiteral("file://"), Qt::CaseInsensitive)) {
                    const auto local = QUrl(text).toLocalFile();
                    if (!local.isEmpty()) {
                        emit openUrl(QUrl::fromLocalFile(local).toString());
                        return;
                    }
                }
            }

            QString directoryError;
            if (!m_impl->cache.ensure(&directoryError)) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("No profile cache directory is configured for the text file."));
                return;
            }

            const auto bytes = found->text.toUtf8();
            QCryptographicHash hash(QCryptographicHash::Sha256);
            hash.addData(bytes);
            const auto path = m_impl->cache.writeFreshFile(
                QStringLiteral("clipboard-") + QString::fromLatin1(hash.result().toHex().left(MAX_NAME_HEX)),
                QStringLiteral("txt"), bytes);
            if (path.isEmpty()) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("The temporary text file could not be written."));
                return;
            }
            emit openUrl(QUrl::fromLocalFile(path).toString());
            return;
        }

        const auto content = found->handle.Content();
        if (content.Contains(StandardDataFormats::StorageItems())) {
            IVectorView<IStorageItem> storageItems {nullptr};
            const auto read = awaitItemStart(
                [&content]() { return content.GetStorageItemsAsync(); },
                // Explicit open: close() already ran, so only shutdown cancels.
                [this]() { return m_impl->session->cancelsRead(0, true); },
                GetTickCount64() + ITEM_READ_TIMEOUT_MS, storageItems);
            if (read == ItemReadStatus::Cancelled)
                return;
            if (read != ItemReadStatus::Completed) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("Windows did not finish reading the clipboard item."));
                return;
            }
            if (storageItems) {
                for (const auto& entry: storageItems) {
                    const auto path = fromHString(entry.Path());
                    if (!path.isEmpty()) {
                        emit openUrl(QUrl::fromLocalFile(path).toString());
                        return;
                    }
                }
            }
        }
        emit operationFinished(QStringLiteral("open"), id, false,
            QStringLiteral("This clipboard item has no openable representation."));
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(QStringLiteral("open"), id, false,
            operationError(QStringLiteral("open the clipboard item"), error));
    } catch (...) {
        emit operationFinished(QStringLiteral("open"), id, false,
            unknownErrorText(QStringLiteral("opening the clipboard item")));
    }
}

} // namespace caelestia::shell::windows
