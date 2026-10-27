#include "windowsclipboardworker.hpp"

#include <chrono>
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
using winrt::Windows::Foundation::IAsyncOperation;

constexpr int EVENT_COALESCE_MS = 150;
// A clipboard image larger than this is not materialized for preview. The
// history entry itself is untouched and copy/paste still works.
constexpr quint64 MAX_PREVIEW_BYTES = 64ULL * 1024ULL * 1024ULL;
constexpr int MAX_ITEMS = 100;
constexpr qsizetype MAX_NAME_HEX = 16;

QString fromHString(const winrt::hstring& value) {
    return QString::fromWCharArray(value.c_str(), static_cast<qsizetype>(value.size()));
}

QString hresultText(const winrt::hresult_error& error) {
    return QStringLiteral("0x%1 %2")
        .arg(static_cast<quint32>(error.code().value), 8, 16, QLatin1Char('0'))
        .arg(fromHString(error.message()));
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

QByteArray readBitmap(const ClipboardHistoryItem& item) {
    const auto content = item.Content();
    if (!content.Contains(StandardDataFormats::Bitmap()))
        return {};

    const auto reference = content.GetBitmapAsync().get();
    if (!reference)
        return {};

    const auto stream = reference.OpenReadAsync().get();
    const auto size = stream.Size();
    if (size == 0 || size > MAX_PREVIEW_BYTES)
        return {};

    winrt::Windows::Storage::Streams::DataReader reader(stream.GetInputStreamAt(0));
    const auto loaded = reader.LoadAsync(static_cast<uint32_t>(size)).get();
    if (static_cast<quint64>(loaded) != size)
        return {};

    std::vector<uint8_t> storage(static_cast<size_t>(size));
    reader.ReadBytes(storage);
    return QByteArray(reinterpret_cast<const char*>(storage.data()),
        static_cast<qsizetype>(storage.size()));
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
                        // Re-check between blocking per-item reads: the picker
                        // may have closed while a text or format read was
                        // waiting.
                        if (session->stopping() || !session->accepts(generation))
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
                            const bool hasText = content.Contains(StandardDataFormats::Text());
                            if (hasText)
                                item.text = fromHString(content.GetTextAsync().get());
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

                    // Previews that no longer belong to an item are deleted
                    // here. Opened text files stay until shutdown.
                    for (auto it = previewFiles.begin(); it != previewFiles.end();) {
                        if (next.contains(it.key())) {
                            ++it;
                        } else {
                            QFile::remove(it.value());
                            it = previewFiles.erase(it);
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
        } catch (const winrt::hresult_error& readError) {
            status = QStringLiteral("error");
            failure = hresultText(readError);
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
        worker.publishSnapshot(list, enabled, status, failure);
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
        qCWarning(logClipboard).noquote() << "init_apartment(multi_threaded) failed:"
                                          << hresultText(error);
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
        qCWarning(logClipboard).noquote() << "Clipboard.HistoryChanged registration failed:"
                                          << hresultText(error);
    } catch (...) {
        qCWarning(logClipboard) << "Clipboard.HistoryChanged registration failed.";
    }
    try {
        impl.enabledToken = Clipboard::HistoryEnabledChanged(queueRefresh);
        impl.enabledRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote()
            << "Clipboard.HistoryEnabledChanged registration failed:" << hresultText(error);
    } catch (...) {
        qCWarning(logClipboard) << "Clipboard.HistoryEnabledChanged registration failed.";
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
        error = hresultText(failure);
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
        publishSnapshot({}, enabled, status, error);
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
            publishSnapshot({}, true, QStringLiteral("error"), hresultText(failure));
        return;
    } catch (...) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
        if (impl.session->accepts(generation)) {
            publishSnapshot({}, true, QStringLiteral("error"),
                unknownErrorText(QStringLiteral("starting the clipboard history read")));
        }
        return;
    }

    if (!operation) {
        if (impl.session->accepts(generation)) {
            publishSnapshot({}, true, QStringLiteral("error"),
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
                    error = hresultText(failure);
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
        if (impl.session->accepts(generation))
            publishSnapshot({}, true, QStringLiteral("error"), hresultText(failure));
    } catch (...) {
        {
            const std::lock_guard lock(impl.asyncMutex);
            if (impl.historyOperation == operation)
                impl.historyOperation = nullptr;
        }
        if (impl.session->accepts(generation)) {
            publishSnapshot({}, true, QStringLiteral("error"),
                unknownErrorText(QStringLiteral("waiting for the clipboard history read")));
        }
    }
}

void WindowsClipboardWorker::publishSnapshot(const QVariantList& items, bool enabled,
    const QString& status, const QString& error) {
    if (!m_impl->running || m_impl->session->stopping() || !m_impl->session->active())
        return;
    if (m_impl->historyEnabled != enabled) {
        m_impl->historyEnabled = enabled;
        emit historyEnabledChanged(enabled);
    }
    emit snapshotReady(items, enabled, status, error);
}

QString WindowsClipboardWorker::ensurePreview(const QString& id) {
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
    try {
        bytes = readBitmap(found->handle);
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "Reading a clipboard bitmap failed:" << hresultText(error);
        return {};
    } catch (...) {
        qCWarning(logClipboard) << "Reading a clipboard bitmap failed with an unknown error.";
        return {};
    }
    if (bytes.isEmpty())
        return {};

    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(bytes);
    const auto name = QString::fromLatin1(hash.result().toHex().left(MAX_NAME_HEX)) + QLatin1Char('.')
        + extensionFor(bytes);
    const auto path = impl.cache.filePath(name);
    if (path.isEmpty())
        return {};

    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qCWarning(logClipboard) << "Could not write a clipboard preview file.";
        return {};
    }
    const auto written = file.write(bytes);
    file.close();
    if (written != bytes.size()) {
        QFile::remove(path);
        qCWarning(logClipboard) << "A clipboard preview file was written incompletely.";
        return {};
    }

    impl.previewFiles.insert(id, path);
    return path;
}

void WindowsClipboardWorker::removePreview(const QString& id) {
    const auto path = m_impl->previewFiles.take(id);
    if (!path.isEmpty())
        QFile::remove(path);
}

void WindowsClipboardWorker::clearPreviews() {
    for (const auto& path: m_impl->previewFiles)
        QFile::remove(path);
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
    qCDebug(logClipboard) << "Clipboard cache" << impl.cache.path() << "dead siblings removed"
                          << removed;
}

void WindowsClipboardWorker::requestImage(const QString& id) {
    if (!m_impl->running || m_impl->session->stopping() || !m_impl->session->active())
        return;

    const auto path = ensurePreview(id);
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
        emit operationFinished(operation, id, false, hresultText(error));
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
        emit operationFinished(QStringLiteral("remove"), id, false, hresultText(error));
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
        emit operationFinished(QStringLiteral("clear"), QString(), false, hresultText(error));
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
            const auto path = ensurePreview(id);
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

            QCryptographicHash hash(QCryptographicHash::Sha256);
            hash.addData(found->text.toUtf8());
            const auto path = m_impl->cache.filePath(QStringLiteral("clipboard-")
                + QString::fromLatin1(hash.result().toHex().left(MAX_NAME_HEX))
                + QStringLiteral(".txt"));
            QFile file(path);
            if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("The temporary text file could not be written."));
                return;
            }
            file.write(found->text.toUtf8());
            file.close();
            emit openUrl(QUrl::fromLocalFile(path).toString());
            return;
        }

        const auto content = found->handle.Content();
        if (content.Contains(StandardDataFormats::StorageItems())) {
            for (const auto& entry: content.GetStorageItemsAsync().get()) {
                const auto path = fromHString(entry.Path());
                if (!path.isEmpty()) {
                    emit openUrl(QUrl::fromLocalFile(path).toString());
                    return;
                }
            }
        }
        emit operationFinished(QStringLiteral("open"), id, false,
            QStringLiteral("This clipboard item has no openable representation."));
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(QStringLiteral("open"), id, false, hresultText(error));
    } catch (...) {
        emit operationFinished(QStringLiteral("open"), id, false,
            unknownErrorText(QStringLiteral("opening the clipboard item")));
    }
}

} // namespace caelestia::shell::windows
