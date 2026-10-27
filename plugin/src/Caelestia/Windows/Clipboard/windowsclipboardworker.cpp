#include "windowsclipboardworker.hpp"

#include <algorithm>
#include <atomic>
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
#include <qset.h>
#include <qstringlist.h>
#include <qtimer.h>
#include <qurl.h>

#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

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
// Crash leftovers are removed at worker start and then periodically; the
// interval only bounds how long a leftover may survive a crash.
constexpr int PREVIEW_PRUNE_INTERVAL_MS = 10 * 60 * 1000;
constexpr int STALE_PREVIEW_HOURS = 24;
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
// preview directory inspectable and avoids claiming every stream is PNG.
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
    }
    return formats.join(QStringLiteral(", "));
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

    QString cacheDirectory;
    QHash<QString, Item> items;
    // Windows returns the history newest first. QHash does not preserve that,
    // so the exposed list follows this explicit order.
    QStringList order;
    QHash<QString, QString> previewFiles;
    ClipboardRefreshGate gate;
    std::shared_ptr<EventBridge> bridge;
    winrt::event_token historyToken {};
    winrt::event_token enabledToken {};
    QTimer* coalesce = nullptr;
    QTimer* pruneTimer = nullptr;
    bool apartment = false;
    bool running = false;
    bool historyRegistered = false;
    bool enabledRegistered = false;
    bool historyEnabled = false;
    bool previewsReconciled = false;
    std::atomic<bool> stopped {false};

    // requestStop() may cancel from the GUI thread while the worker thread is
    // blocked inside a WinRT call.
    std::mutex asyncMutex;
    IAsyncOperation<ClipboardHistoryItemsResult> historyOperation {nullptr};

    // The history result is applied on the worker thread only, but the method
    // lives here so the WinRT type never appears in the public header. As a
    // nested class it can reach the worker's private members.
    void applyHistory(WindowsClipboardWorker& worker, quint64 generation, bool eventDriven,
        const ClipboardHistoryItemsResult& result, bool ok, const QString& error) {
        if (!running || stopped.load())
            return;
        if (!gate.accepts(generation))
            return;
        if (eventDriven && !gate.active())
            return;

        QVariantList list;
        QString status = QStringLiteral("ready");
        QString failure = error;
        bool enabled = true;

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
                        // Keep the entry; a format that cannot be read must not
                        // hide the rest of the history.
                        item.kind = QStringLiteral("other");
                        item.text.clear();
                    }
                    next.insert(id, item);
                    nextOrder.append(id);
                }

                // Previews that no longer belong to an item are deleted here.
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

        if (status != QStringLiteral("ready")) {
            items.clear();
            order.clear();
            worker.clearPreviews();
        }

        worker.publishSnapshot(list, enabled, status, failure);
    }
};

WindowsClipboardWorker::WindowsClipboardWorker(QString cacheDirectory, QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>()) {
    m_impl->cacheDirectory = std::move(cacheDirectory);
}

WindowsClipboardWorker::~WindowsClipboardWorker() {
    // The facade joins the thread before deleting the worker, or hands both to
    // QThread::finished when a WinRT call never returns. In either case the
    // owning thread is no longer running here.
    if (m_impl->running)
        end();
}

void WindowsClipboardWorker::begin() {
    auto& impl = *m_impl;
    if (impl.running || impl.stopped.load())
        return;
    impl.running = true;

    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        impl.apartment = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "init_apartment(multi_threaded) failed:" << hresultText(error);
    }

    impl.coalesce = new QTimer(this);
    impl.coalesce->setSingleShot(true);
    impl.coalesce->setInterval(EVENT_COALESCE_MS);
    connect(impl.coalesce, &QTimer::timeout, this, [this]() {
        auto& impl = *m_impl;
        if (!impl.running || impl.stopped.load() || impl.coalesce == nullptr)
            return;
        // Closing the picker invalidates the pending event before this fires.
        if (impl.gate.onTimeout() != ClipboardRefreshGate::TimeoutDecision::Refresh)
            return;
        performRefresh(true);
    });

    impl.pruneTimer = new QTimer(this);
    impl.pruneTimer->setInterval(PREVIEW_PRUNE_INTERVAL_MS);
    connect(impl.pruneTimer, &QTimer::timeout, this, [this]() { reconcilePreviews(false); });
    impl.pruneTimer->start();

    // Static event handlers run on WinRT callback threads. They hold the
    // shared bridge and never capture the worker directly.
    impl.bridge = std::make_shared<Impl::EventBridge>();
    impl.bridge->worker = this;
    const auto bridge = impl.bridge;
    const auto queueRefresh = [bridge](auto&&, auto&&) {
        const std::lock_guard lock(bridge->mutex);
        if (!bridge->alive || bridge->worker == nullptr)
            return;
        auto* worker = bridge->worker;
        QMetaObject::invokeMethod(
            worker,
            [bridge]() {
                const std::lock_guard guard(bridge->mutex);
                if (!bridge->alive || bridge->worker == nullptr)
                    return;
                bridge->worker->scheduleEventRefresh();
            },
            Qt::QueuedConnection);
    };

    // Each subscription is revoked independently: one failing must not leave
    // the other registered.
    try {
        impl.historyToken = Clipboard::HistoryChanged(queueRefresh);
        impl.historyRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "Clipboard.HistoryChanged registration failed:"
                                          << hresultText(error);
    }
    try {
        impl.enabledToken = Clipboard::HistoryEnabledChanged(queueRefresh);
        impl.enabledRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "Clipboard.HistoryEnabledChanged registration failed:"
                                          << hresultText(error);
    }
}

void WindowsClipboardWorker::end() {
    auto& impl = *m_impl;
    requestStop();
    impl.running = false;

    impl.gate.setActive(false);

    if (impl.coalesce != nullptr) {
        impl.coalesce->stop();
        delete impl.coalesce;
        impl.coalesce = nullptr;
    }
    if (impl.pruneTimer != nullptr) {
        impl.pruneTimer->stop();
        delete impl.pruneTimer;
        impl.pruneTimer = nullptr;
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
    }
    impl.historyRegistered = false;

    try {
        if (impl.enabledRegistered)
            Clipboard::HistoryEnabledChanged(impl.enabledToken);
    } catch (const winrt::hresult_error&) {
        // Shutdown must not depend on event unregistration succeeding.
    }
    impl.enabledRegistered = false;

    impl.items.clear();
    impl.order.clear();
    // An orderly shutdown must not leave this session's previews or opened
    // text files behind for the next start to reconcile.
    clearPreviews();
    removeOpenFiles();

    if (impl.apartment) {
        try {
            winrt::uninit_apartment();
        } catch (const winrt::hresult_error&) {
            // The process is shutting down; there is nothing useful to do.
        }
        impl.apartment = false;
    }
}

void WindowsClipboardWorker::requestStop() {
    auto& impl = *m_impl;
    impl.stopped.store(true);
    const std::lock_guard lock(impl.asyncMutex);
    if (impl.historyOperation) {
        try {
            impl.historyOperation.Cancel();
        } catch (const winrt::hresult_error&) {
            // Best effort: the bounded join in the facade still applies.
        }
        impl.historyOperation = nullptr;
    }
}

void WindowsClipboardWorker::setActive(bool active) {
    auto& impl = *m_impl;
    if (impl.stopped.load())
        return;

    impl.gate.setActive(active);
    // A closed picker must not leave a coalesced read pending, and a new
    // session starts without an event from the previous one.
    if (impl.coalesce != nullptr)
        impl.coalesce->stop();
}

void WindowsClipboardWorker::refresh() {
    if (!m_impl->running || m_impl->stopped.load())
        return;
    performRefresh(false);
}

void WindowsClipboardWorker::scheduleEventRefresh() {
    auto& impl = *m_impl;
    if (!impl.running || impl.stopped.load() || impl.coalesce == nullptr)
        return;
    if (impl.gate.onEvent() != ClipboardRefreshGate::EventDecision::Schedule)
        return;
    impl.coalesce->start();
}

void WindowsClipboardWorker::performRefresh(bool eventDriven) {
    auto& impl = *m_impl;
    if (!impl.running || impl.stopped.load())
        return;

    // Every read starts a new generation; a completion that arrives after a
    // newer read or a picker close is not published.
    const auto generation = impl.gate.nextRead();

    QString status = QStringLiteral("ready");
    QString error;
    bool enabled = false;

    try {
        enabled = Clipboard::IsHistoryEnabled();
    } catch (const winrt::hresult_error& failure) {
        status = QStringLiteral("error");
        error = hresultText(failure);
    }

    if (status == QStringLiteral("ready") && !enabled)
        status = QStringLiteral("disabled");

    if (status != QStringLiteral("ready")) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
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

    IAsyncOperation<ClipboardHistoryItemsResult> operation {nullptr};
    try {
        operation = Clipboard::GetHistoryItemsAsync();
    } catch (const winrt::hresult_error& failure) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
        publishSnapshot({}, true, QStringLiteral("error"), hresultText(failure));
        return;
    }

    {
        const std::lock_guard lock(impl.asyncMutex);
        if (impl.stopped.load()) {
            try {
                operation.Cancel();
            } catch (const winrt::hresult_error&) {
            }
            return;
        }
        impl.historyOperation = operation;
    }

    const auto bridge = impl.bridge;
    if (bridge == nullptr)
        return;

    operation.Completed([bridge, generation, eventDriven](
                            const IAsyncOperation<ClipboardHistoryItemsResult>& sender,
                            AsyncStatus asyncStatus) {
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
        }

        // Post while holding the bridge lock. end() marks the bridge dead
        // under the same lock, so the worker cannot be destroyed between the
        // liveness check and the queued invocation.
        {
            const std::lock_guard lock(bridge->mutex);
            if (!bridge->alive || bridge->worker == nullptr)
                return;
            auto* worker = bridge->worker;
            QMetaObject::invokeMethod(
                worker,
                [bridge, generation, eventDriven, result, ok, error]() {
                    WindowsClipboardWorker* target = nullptr;
                    {
                        const std::lock_guard guard(bridge->mutex);
                        if (!bridge->alive || bridge->worker == nullptr)
                            return;
                        target = bridge->worker;
                    }
                    target->m_impl->applyHistory(*target, generation, eventDriven, result, ok, error);
                },
                Qt::QueuedConnection);
        }
    });
}

void WindowsClipboardWorker::publishSnapshot(const QVariantList& items, bool enabled,
    const QString& status, const QString& error) {
    if (m_impl->historyEnabled != enabled) {
        m_impl->historyEnabled = enabled;
        emit historyEnabledChanged(enabled);
    }
    emit snapshotReady(items, enabled, status, error);
}

QString WindowsClipboardWorker::previewDirectory() const {
    if (m_impl->cacheDirectory.isEmpty())
        return {};
    return m_impl->cacheDirectory + QStringLiteral("/preview");
}

QString WindowsClipboardWorker::openDirectory() const {
    if (m_impl->cacheDirectory.isEmpty())
        return {};
    return m_impl->cacheDirectory + QStringLiteral("/open");
}

void WindowsClipboardWorker::reconcilePreviews(bool startup) {
    if (m_impl->cacheDirectory.isEmpty())
        return;

    // Preview files are regenerable and owned only by this session. Anything
    // in the preview directory that this session does not own is a leftover
    // from a previous run (a crash, or a session that never reached end()).
    QSet<QString> owned;
    owned.reserve(m_impl->previewFiles.size());
    for (const auto& path: m_impl->previewFiles)
        owned.insert(QDir::cleanPath(path));

    const QDir preview(previewDirectory());
    if (preview.exists()) {
        const auto files = preview.entryInfoList(QDir::Files | QDir::NoDotAndDotDot);
        for (const auto& file: files) {
            if (!owned.contains(QDir::cleanPath(file.absoluteFilePath())))
                QFile::remove(file.absoluteFilePath());
        }
    }

    // The open directory only ever holds this session's explicit "open as
    // text" files. At startup every file is a leftover; during a session only
    // files that the prune threshold marks stale are removed.
    const QDir open(openDirectory());
    if (open.exists()) {
        const auto now = QDateTime::currentDateTimeUtc();
        const auto files = open.entryInfoList(QDir::Files | QDir::NoDotAndDotDot);
        for (const auto& file: files) {
            if (startup || file.lastModified().toUTC().secsTo(now) > STALE_PREVIEW_HOURS * 3600)
                QFile::remove(file.absoluteFilePath());
        }
    }
}

void WindowsClipboardWorker::removeOpenFiles() {
    const QDir directory(openDirectory());
    if (!directory.exists())
        return;
    const auto files = directory.entryInfoList(QDir::Files | QDir::NoDotAndDotDot);
    for (const auto& file: files)
        QFile::remove(file.absoluteFilePath());
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

    const auto directory = previewDirectory();
    if (directory.isEmpty()) {
        qCWarning(logClipboard) << "No profile cache directory is configured; image previews are unavailable.";
        return {};
    }

    QByteArray bytes;
    try {
        bytes = readBitmap(found->handle);
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "Reading a clipboard bitmap failed:" << hresultText(error);
        return {};
    }
    if (bytes.isEmpty())
        return {};

    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(bytes);
    const auto name = QString::fromLatin1(hash.result().toHex().left(MAX_NAME_HEX)) + QLatin1Char('.')
        + extensionFor(bytes);

    if (!QDir().mkpath(directory)) {
        qCWarning(logClipboard) << "Could not create the clipboard preview directory.";
        return {};
    }

    const auto path = directory + QLatin1Char('/') + name;
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

void WindowsClipboardWorker::setCacheDirectory(const QString& directory) {
    if (directory == m_impl->cacheDirectory)
        return;
    if (!directory.isEmpty() && !QDir::isAbsolutePath(directory)) {
        qCWarning(logClipboard) << "Ignoring a relative clipboard cache directory.";
        return;
    }

    clearPreviews();
    m_impl->cacheDirectory = directory;

    const bool startup = !m_impl->previewsReconciled && !directory.isEmpty();
    if (!directory.isEmpty())
        m_impl->previewsReconciled = true;
    reconcilePreviews(startup);
}

void WindowsClipboardWorker::requestImage(const QString& id) {
    if (!m_impl->running || m_impl->stopped.load())
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
    if (!m_impl->running || m_impl->stopped.load())
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
    }
}

void WindowsClipboardWorker::removeItem(const QString& id) {
    if (!m_impl->running || m_impl->stopped.load())
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
    }

    removePreview(id);
    m_impl->items.erase(found);
    m_impl->order.removeAll(id);
    emit operationFinished(QStringLiteral("remove"), id, true, QString());
    performRefresh(false);
}

void WindowsClipboardWorker::clearHistory() {
    if (!m_impl->running || m_impl->stopped.load())
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
    }

    clearPreviews();
    m_impl->items.clear();
    m_impl->order.clear();
    emit operationFinished(QStringLiteral("clear"), QString(), true, QString());
    performRefresh(false);
}

void WindowsClipboardWorker::openItem(const QString& id) {
    if (!m_impl->running || m_impl->stopped.load())
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

            const auto directoryPath = openDirectory();
            if (directoryPath.isEmpty()) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("No profile cache directory is configured for the text file."));
                return;
            }
            const QDir directory(directoryPath);
            if (!QDir().mkpath(directory.path())) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("The temporary text file could not be created."));
                return;
            }
            // This directory holds only the text most recently opened from the
            // picker, so superseded copies are removed first.
            for (const auto& entry: directory.entryInfoList(QDir::Files | QDir::NoDotAndDotDot))
                QFile::remove(entry.absoluteFilePath());

            QCryptographicHash hash(QCryptographicHash::Sha256);
            hash.addData(found->text.toUtf8());
            const auto path = directory.filePath(QStringLiteral("clipboard-")
                + QString::fromLatin1(hash.result().toHex().left(MAX_NAME_HEX)) + QStringLiteral(".txt"));
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
    }
}

} // namespace caelestia::shell::windows
