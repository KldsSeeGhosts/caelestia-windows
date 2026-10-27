#include "windowsclipboardworker.hpp"

#include <algorithm>
#include <chrono>
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
#include <qstringlist.h>
#include <qtimer.h>
#include <qurl.h>

#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

namespace caelestia::shell::windows {

namespace {

Q_LOGGING_CATEGORY(logClipboard, "caelestia.windows.clipboard")

using winrt::Windows::ApplicationModel::DataTransfer::Clipboard;
using winrt::Windows::ApplicationModel::DataTransfer::ClipboardHistoryItem;
using winrt::Windows::ApplicationModel::DataTransfer::ClipboardHistoryItemsResult;
using winrt::Windows::ApplicationModel::DataTransfer::ClipboardHistoryItemsResultStatus;
using winrt::Windows::ApplicationModel::DataTransfer::DataPackageView;
using winrt::Windows::ApplicationModel::DataTransfer::StandardDataFormats;

constexpr int EVENT_COALESCE_MS = 150;
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
    winrt::event_token historyToken {};
    winrt::event_token enabledToken {};
    QTimer* coalesce = nullptr;
    bool apartment = false;
    bool running = false;
    bool active = false;
    bool historyRegistered = false;
    bool enabledRegistered = false;
    bool historyEnabled = false;
};

WindowsClipboardWorker::WindowsClipboardWorker(QString cacheDirectory, QObject* parent)
    : QObject(parent)
    , m_impl(std::make_unique<Impl>()) {
    m_impl->cacheDirectory = std::move(cacheDirectory);
}

WindowsClipboardWorker::~WindowsClipboardWorker() = default;

void WindowsClipboardWorker::begin() {
    auto& impl = *m_impl;
    if (impl.running)
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
    connect(impl.coalesce, &QTimer::timeout, this, &WindowsClipboardWorker::performRefresh);

    // Static event handlers run on WinRT callback threads. Queue one coalesced
    // read on this worker; the receiver context drops the call if the worker
    // is destroyed first.
    const auto queueRefresh = [this]() {
        QMetaObject::invokeMethod(
            this,
            [this]() {
                if (!m_impl->running || !m_impl->active || m_impl->coalesce == nullptr)
                    return;
                m_impl->coalesce->start();
            },
            Qt::QueuedConnection);
    };

    try {
        impl.historyToken = Clipboard::HistoryChanged([queueRefresh](auto&&, auto&&) { queueRefresh(); });
        impl.historyRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "Clipboard.HistoryChanged registration failed:"
                                          << hresultText(error);
    }
    try {
        impl.enabledToken
            = Clipboard::HistoryEnabledChanged([queueRefresh](auto&&, auto&&) { queueRefresh(); });
        impl.enabledRegistered = true;
    } catch (const winrt::hresult_error& error) {
        qCWarning(logClipboard).noquote() << "Clipboard.HistoryEnabledChanged registration failed:"
                                          << hresultText(error);
    }

    pruneStalePreviews();
}

void WindowsClipboardWorker::end() {
    auto& impl = *m_impl;
    impl.running = false;
    impl.active = false;

    if (impl.coalesce != nullptr) {
        impl.coalesce->stop();
        delete impl.coalesce;
        impl.coalesce = nullptr;
    }

    try {
        if (impl.historyRegistered)
            Clipboard::HistoryChanged(impl.historyToken);
        if (impl.enabledRegistered)
            Clipboard::HistoryEnabledChanged(impl.enabledToken);
    } catch (const winrt::hresult_error&) {
        // Shutdown must not depend on event unregistration succeeding.
    }
    impl.historyRegistered = false;
    impl.enabledRegistered = false;

    impl.items.clear();
    impl.order.clear();
    impl.previewFiles.clear();

    if (impl.apartment) {
        winrt::uninit_apartment();
        impl.apartment = false;
    }
}

void WindowsClipboardWorker::setActive(bool active) {
    // The picker calls refresh() itself when it opens; this only decides
    // whether change events keep the open picker current.
    m_impl->active = active;
}

void WindowsClipboardWorker::refresh() { performRefresh(); }

void WindowsClipboardWorker::performRefresh() {
    auto& impl = *m_impl;
    if (!impl.running)
        return;

    QVariantList list;
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

    if (status == QStringLiteral("ready")) {
        try {
            const auto result = Clipboard::GetHistoryItemsAsync().get();
            const auto resultStatus = result.Status();
            if (resultStatus == ClipboardHistoryItemsResultStatus::ClipboardHistoryDisabled) {
                status = QStringLiteral("disabled");
            } else if (resultStatus == ClipboardHistoryItemsResultStatus::AccessDenied) {
                status = QStringLiteral("denied");
                error = QStringLiteral("Windows refused access to clipboard history.");
            } else if (resultStatus != ClipboardHistoryItemsResultStatus::Success) {
                status = QStringLiteral("error");
                error = QStringLiteral("Windows returned clipboard history status %1.")
                            .arg(static_cast<int>(resultStatus));
            } else {
                QHash<QString, Impl::Item> next;
                QStringList nextOrder;
                for (const auto& handle: result.Items()) {
                    if (next.size() >= static_cast<qsizetype>(MAX_ITEMS))
                        break;
                    const auto id = fromHString(handle.Id());
                    if (id.isEmpty() || next.contains(id))
                        continue;

                    Impl::Item item;
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
                for (auto it = impl.previewFiles.begin(); it != impl.previewFiles.end();) {
                    if (next.contains(it.key())) {
                        ++it;
                    } else {
                        QFile::remove(it.value());
                        it = impl.previewFiles.erase(it);
                    }
                }

                impl.items = std::move(next);
                impl.order = nextOrder;

                for (const auto& id: impl.order) {
                    const auto& item = impl.items.value(id);
                    const auto previewPath = impl.previewFiles.value(id);
                    QVariantMap values;
                    values.insert(QStringLiteral("id"), id);
                    values.insert(QStringLiteral("kind"), item.kind);
                    values.insert(QStringLiteral("text"), item.text);
                    values.insert(QStringLiteral("imageUrl"),
                        previewPath.isEmpty() ? QString() : QUrl::fromLocalFile(previewPath).toString());
                    values.insert(QStringLiteral("timestamp"), item.timestamp);
                    values.insert(QStringLiteral("timestampLabel"), item.timestampLabel);
                    values.insert(QStringLiteral("formats"), item.formats);
                    list.append(values);
                }
            }
        } catch (const winrt::hresult_error& failure) {
            status = QStringLiteral("error");
            error = hresultText(failure);
        }
    }

    if (impl.historyEnabled != enabled) {
        impl.historyEnabled = enabled;
        emit historyEnabledChanged(enabled);
    }

    if (status != QStringLiteral("ready")) {
        impl.items.clear();
        impl.order.clear();
        clearPreviews();
    }

    emit snapshotReady(list, enabled, status, error);
}

QString WindowsClipboardWorker::previewDirectory() const {
    if (m_impl->cacheDirectory.isEmpty())
        return {};
    return m_impl->cacheDirectory + QStringLiteral("/preview");
}

void WindowsClipboardWorker::pruneStalePreviews() {
    if (m_impl->cacheDirectory.isEmpty())
        return;

    const auto now = QDateTime::currentDateTimeUtc();
    for (const auto& name: {QStringLiteral("preview"), QStringLiteral("open")}) {
        const QDir directory(m_impl->cacheDirectory + QLatin1Char('/') + name);
        if (!directory.exists())
            continue;
        const auto files = directory.entryInfoList(QDir::Files | QDir::NoDotAndDotDot);
        for (const auto& file: files) {
            if (file.lastModified().toUTC().secsTo(now) > STALE_PREVIEW_HOURS * 3600)
                QFile::remove(file.absoluteFilePath());
        }
    }
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
    pruneStalePreviews();
}

void WindowsClipboardWorker::requestImage(const QString& id) {
    if (!m_impl->running)
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
    const auto operation = paste ? QStringLiteral("paste") : QStringLiteral("copy");
    const auto found = m_impl->items.constFind(id);
    if (found == m_impl->items.constEnd()) {
        emit operationFinished(operation, id, false,
            QStringLiteral("The clipboard item is no longer in the history."));
        return;
    }

    try {
        // Windows applies its own rules for the restored item; the shell never
        // writes a parallel clipboard format or history entry.
        Clipboard::SetHistoryItemAsContent(found->handle);
        emit operationFinished(operation, id, true, QString());
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(operation, id, false, hresultText(error));
    }
}

void WindowsClipboardWorker::removeItem(const QString& id) {
    const auto found = m_impl->items.find(id);
    if (found == m_impl->items.end()) {
        emit operationFinished(QStringLiteral("remove"), id, false,
            QStringLiteral("The clipboard item is no longer in the history."));
        return;
    }

    try {
        Clipboard::DeleteItemFromHistory(found->handle);
        removePreview(id);
        m_impl->items.erase(found);
        m_impl->order.removeAll(id);
        emit operationFinished(QStringLiteral("remove"), id, true, QString());
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(QStringLiteral("remove"), id, false, hresultText(error));
        return;
    }
    performRefresh();
}

void WindowsClipboardWorker::clearHistory() {
    try {
        // Windows owns what ClearHistory removes, including pinned items.
        Clipboard::ClearHistory();
    } catch (const winrt::hresult_error& error) {
        emit operationFinished(QStringLiteral("clear"), QString(), false, hresultText(error));
        return;
    }
    clearPreviews();
    m_impl->items.clear();
    m_impl->order.clear();
    emit operationFinished(QStringLiteral("clear"), QString(), true, QString());
    performRefresh();
}

void WindowsClipboardWorker::openItem(const QString& id) {
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

            if (m_impl->cacheDirectory.isEmpty()) {
                emit operationFinished(QStringLiteral("open"), id, false,
                    QStringLiteral("No profile cache directory is configured for the text file."));
                return;
            }
            const QDir directory(m_impl->cacheDirectory + QStringLiteral("/open"));
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
