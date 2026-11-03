#include "settingsfile.hpp"

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qloggingcategory.h>
#include <qsavefile.h>

#include <utility>

#include "redact.hpp"
#include "util/i18n.hpp"

namespace {

Q_LOGGING_CATEGORY(lcSettingsFile, "caelestia.settings.file", QtInfoMsg)

} // namespace

namespace caelestia::shell::settings {

// Layer files live under per-monitor directories named after the monitor, so
// every log of m_path goes through logId().
using Qt::StringLiterals::operator""_s;
using util::i18n::mark;

namespace {

// Max retries for loads which fail due to malformed JSON, e.g. partial writes
constexpr int k_maxLoadRetries = 3;

// Windows: max retries for failed saves (e.g. transient file locks), with exponential backoff (#118)
constexpr int k_maxSaveRetries = 5;
constexpr int k_saveRetryBaseMs = 1000;

} // namespace

SettingsFile::SettingsFile(bool watch, QString path, QObject* parent)
    : QObject(parent)
    , m_path(std::move(path))
    , m_watcher(watch ? new QFileSystemWatcher(this) : nullptr)
    , m_saveDebounce(new QTimer(this))
    , m_loadDebounce(watch ? new QTimer(this) : nullptr)
    , m_saveRetry(new QTimer(this))
    , m_loadRetries(0)
    , m_saveRetries(0) {
    m_saveRetry->setSingleShot(true);
    QObject::connect(m_saveRetry, &QTimer::timeout, this, &SettingsFile::writeNow);

    m_saveDebounce->setSingleShot(true);
    m_saveDebounce->setInterval(500); // Save at most once every 500ms

    if (!watch)
        return;

    m_loadDebounce->setSingleShot(true);
    m_loadDebounce->setInterval(50); // Coalesce watcher events within 50ms
    QObject::connect(m_loadDebounce, &QTimer::timeout, this, &SettingsFile::onLoadDebounced);

    QObject::connect(m_watcher, &QFileSystemWatcher::fileChanged, this, &SettingsFile::onFileChanged);
    QObject::connect(m_watcher, &QFileSystemWatcher::directoryChanged, this, &SettingsFile::onDirChanged);

    initWatcher();
}

SettingsFile::~SettingsFile() {
    writeNow();
}

std::optional<QJsonValue> SettingsFile::read() const {
    return m_lastData;
}

void SettingsFile::write(const QJsonValue& json) {
    m_pendingWrite = json;
    m_saveRetries = 0;
    m_saveRetry->stop();
    save();
}

void SettingsFile::flush() {
    writeNow();
}

void SettingsFile::onFileChanged() {
    initWatcher(); // Re-add path in case the file was replaced
    scheduleLoad();
}

void SettingsFile::onDirChanged() {
    // Ignore if the file is already watched
    if (m_watcher->files().contains(m_path))
        return;

    initWatcher();

    if (QFile::exists(m_path))
        scheduleLoad();
}

void SettingsFile::initWatcher() {
    if (!m_watcher)
        return;

    const QFileInfo info(m_path);
    const auto dir = info.absolutePath();

    if (QDir(dir).exists() && !m_watcher->directories().contains(dir))
        m_watcher->addPath(dir);

    if (info.exists() && !m_watcher->files().contains(m_path))
        m_watcher->addPath(m_path);
}

void SettingsFile::scheduleLoad() {
    // Ignore if not watching or a load is already pending
    if (!m_loadDebounce || m_loadDebounce->isActive())
        return;

    m_loadRetries = 0;
    m_loadDebounce->start();
}

void SettingsFile::onLoadDebounced() {
    const auto isFinalTry = m_loadRetries >= k_maxLoadRetries;

    if (load(isFinalTry) == LoadResult::ParseError && !isFinalTry) {
        // Likely a partial write, retry after another debounce
        ++m_loadRetries;
        qCDebug(lcSettingsFile, "Retrying load of %s (%d/%d)", qUtf8Printable(logId(m_path)), m_loadRetries, k_maxLoadRetries);
        m_loadDebounce->start();
    }
}

SettingsFile::LoadResult SettingsFile::load(bool reportErrors) {
    QFile file(m_path);

    if (!file.exists()) {
        if (m_lastData) {
            m_lastData = std::nullopt;
            emit changed();
            return LoadResult::Changed;
        }
        return LoadResult::Unchanged;
    }

    if (!file.open(QIODevice::ReadOnly)) {
        qCWarning(lcSettingsFile, "Failed to open %s for reading: %s", qUtf8Printable(logId(m_path)),
            qUtf8Printable(file.errorString()));
        emit readFailed(mark(u"Failed to open: %1"_s, { file.errorString() }));
        return LoadResult::Error;
    }

    const auto data = file.readAll();
    file.close();

    QJsonParseError error;
    const auto doc = QJsonDocument::fromJson(data, &error);

    if (error.error != QJsonParseError::NoError) {
        if (reportErrors) {
            qCWarning(lcSettingsFile, "Failed to parse %s as JSON: %s", qUtf8Printable(logId(m_path)),
                qUtf8Printable(error.errorString()));
            emit readFailed(mark(u"Failed to parse: %1"_s, { error.errorString() }));
        } else {
            qCDebug(lcSettingsFile, "Failed to parse %s as JSON: %s", qUtf8Printable(logId(m_path)),
                qUtf8Printable(error.errorString()));
        }
        return LoadResult::ParseError;
    }

    const auto json = doc.isObject() ? QJsonValue(doc.object()) : QJsonValue(doc.array());

    if (json == m_lastData)
        return LoadResult::Unchanged;

    // Clear pending write, stuff loaded from file should take precedence
    m_pendingWrite = std::nullopt;

    m_lastData = json;
    emit changed();

    // Only the size: the settings can hold identifiers (monitor names in
    // per-screen overrides, device ids), so their content stays out of the log.
    qCDebug(lcSettingsFile) << "Read JSON from" << logId(m_path) << "with"
                            << (json.isObject() ? json.toObject().size() : json.toArray().size())
                            << "top-level entries";

    return LoadResult::Changed;
}

void SettingsFile::save() {
    if (!m_pendingWrite)
        return;

    if (m_saveDebounce->isActive()) {
        // Queue save for debounce end
        QObject::connect(m_saveDebounce, &QTimer::timeout, this, &SettingsFile::save,
            // NOLINTNEXTLINE(clang-analyzer-optin.core.EnumCastOutOfRange) ConnectionType is OR-able by design
            static_cast<Qt::ConnectionType>(Qt::UniqueConnection | Qt::SingleShotConnection));
        return;
    }

    // Debounce regardless of whether the save actually succeeded
    m_saveDebounce->start();
    writeNow();
}

void SettingsFile::scheduleSaveRetry() {
    if (m_saveRetries >= k_maxSaveRetries) {
        qCWarning(lcSettingsFile, "Giving up saving %s after %d retries", qUtf8Printable(logId(m_path)), m_saveRetries);
        return;
    }

    m_saveRetry->start(k_saveRetryBaseMs << m_saveRetries++);
}

void SettingsFile::writeNow() {
    if (!m_pendingWrite)
        return;

    // Keep the pending write until it is committed, so failures can be retried
    const auto json = *m_pendingWrite;
    const auto data = (json.isObject() ? QJsonDocument(json.toObject()) : QJsonDocument(json.toArray())).toJson();

    const auto dir = QFileInfo(m_path).absolutePath();

    if (!QDir().mkpath(dir)) {
        qCWarning(lcSettingsFile) << "Failed to create dir" << dir;
        emit writeFailed(mark(u"Failed to create parent directory"_s));
        scheduleSaveRetry();
        return;
    }

    // Write atomically
    QSaveFile file(m_path);

    if (!file.open(QIODevice::WriteOnly)) {
        qCWarning(lcSettingsFile, "Failed to open %s for writing: %s", qUtf8Printable(logId(m_path)),
            qUtf8Printable(file.errorString()));
        emit writeFailed(mark(u"Failed to open: %1"_s, { file.errorString() }));
        scheduleSaveRetry();
        return;
    }

    file.write(data);

    if (!file.commit()) {
        qCWarning(lcSettingsFile, "Failed to write %s: %s", qUtf8Printable(logId(m_path)), qUtf8Printable(file.errorString()));
        emit writeFailed(mark(u"Failed to write: %1"_s, { file.errorString() }));
        scheduleSaveRetry();
        return;
    }

    // Only clear the pending write if it wasn't replaced meanwhile
    if (m_pendingWrite && *m_pendingWrite == json)
        m_pendingWrite = std::nullopt;
    m_saveRetries = 0;
    m_saveRetry->stop();
    m_lastData = json;
    qCDebug(lcSettingsFile) << "Saved" << logId(m_path);

    initWatcher(); // The file may have just been created, or replaced by the rename
}

} // namespace caelestia::shell::settings
