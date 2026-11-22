#include "filesystemmodel.hpp"

#include <qdiriterator.h>
#include <qloggingcategory.h>
// Windows: file listing does not require a multimedia backend.
#ifndef CAELESTIA_PORTABLE_UI
#include <qmediaformat.h>
#endif
#include <qtconcurrentrun.h>

#include <algorithm>
#include <optional>
#include <utility>

namespace caelestia::shell::models {

using Qt::StringLiterals::operator""_s;
using Qt::StringLiterals::operator""_ba;

FileSystemEntry::FileSystemEntry(const QString& path, QString relativePath, QObject* parent)
    : QObject(parent)
    , m_fileInfo(path)
    , m_path(path)
    , m_relativePath(std::move(relativePath))
    , m_isImageInitialised(false)
    , m_mimeTypeInitialised(false) {}

QString FileSystemEntry::path() const {
    return m_path;
};

QString FileSystemEntry::relativePath() const {
    return m_relativePath;
};

QString FileSystemEntry::name() const {
    return m_fileInfo.fileName();
};

QString FileSystemEntry::baseName() const {
    return m_fileInfo.baseName();
};

QString FileSystemEntry::parentDir() const {
    return m_fileInfo.absolutePath();
};

QString FileSystemEntry::suffix() const {
    return m_fileInfo.suffix();
};

qint64 FileSystemEntry::size() const {
    return m_fileInfo.size();
};

bool FileSystemEntry::isDir() const {
    return m_fileInfo.isDir();
};

bool FileSystemEntry::isImage() const {
    if (!m_isImageInitialised) {
        // canRead() opens and sniffs the file; the extension gate keeps that
        // cost off entries that cannot decode anyway.
        static const QSet<QString> k_extensions = [] {
            QSet<QString> set;
            for (const auto& format : QImageReader::supportedImageFormats())
                set << QString::fromUtf8(format).toLower();
            return set;
        }();
        m_isImage = k_extensions.contains(m_fileInfo.suffix().toLower()) && QImageReader(m_path).canRead();
        m_isImageInitialised = true;
    }
    return m_isImage;
}

QString FileSystemEntry::mimeType() const {
    if (!m_mimeTypeInitialised) {
        static const QMimeDatabase k_db;
        // MatchExtension alone never sniffs file contents; only an extension
        // the database cannot resolve pays for the content lookup.
        auto mime = k_db.mimeTypeForFile(m_path, QMimeDatabase::MatchExtension);
        if (!mime.isValid() || mime.isDefault())
            mime = k_db.mimeTypeForFile(m_path);
        m_mimeType = mime.name();
        m_mimeTypeInitialised = true;
    }
    return m_mimeType;
}

void FileSystemEntry::updateRelativePath(const QDir& dir) {
    const auto relPath = dir.relativeFilePath(m_path);
    if (m_relativePath != relPath) {
        m_relativePath = relPath;
        emit relativePathChanged();
    }
}

FileSystemModel::FileSystemModel(QObject* parent)
    : QAbstractListModel(parent)
    , m_recursive(false)
    , m_watchChanges(true)
    , m_showHidden(false)
    , m_filter(Filter::NoFilter) {
    // A directoryChanged burst triggers one debounced update per touched
    // directory; each update's single traversal also collects the
    // subdirectories to watch instead of scanning a second time.
    m_debounceTimer.setSingleShot(true);
    m_debounceTimer.setInterval(100);
    connect(&m_debounceTimer, &QTimer::timeout, this, &FileSystemModel::processPendingDirs);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &FileSystemModel::onDirChanged);
}

int FileSystemModel::rowCount(const QModelIndex& parent) const {
    if (parent != QModelIndex()) {
        return 0;
    }
    return static_cast<int>(m_entries.size());
}

QVariant FileSystemModel::data(const QModelIndex& index, int role) const {
    if (role != Qt::UserRole || !index.isValid() || index.row() >= m_entries.size()) {
        return {};
    }
    return QVariant::fromValue(m_entries.at(index.row()));
}

QHash<int, QByteArray> FileSystemModel::roleNames() const {
    return { { Qt::UserRole, "modelData"_ba } };
}

QString FileSystemModel::path() const {
    return m_path;
}

void FileSystemModel::setPath(const QString& path) {
    if (m_path == path) {
        return;
    }

    m_path = path;
    emit pathChanged();

    m_dir.setPath(m_path);

    for (const auto& entry : std::as_const(m_entries)) {
        entry->updateRelativePath(m_dir);
    }

    update();
}

bool FileSystemModel::recursive() const {
    return m_recursive;
}

void FileSystemModel::setRecursive(bool recursive) {
    if (m_recursive == recursive) {
        return;
    }

    m_recursive = recursive;
    emit recursiveChanged();

    update();
}

bool FileSystemModel::watchChanges() const {
    return m_watchChanges;
}

void FileSystemModel::setWatchChanges(bool watchChanges) {
    if (m_watchChanges == watchChanges) {
        return;
    }

    m_watchChanges = watchChanges;
    emit watchChangesChanged();

    update();
}

bool FileSystemModel::showHidden() const {
    return m_showHidden;
}

void FileSystemModel::setShowHidden(bool showHidden) {
    if (m_showHidden == showHidden) {
        return;
    }

    m_showHidden = showHidden;
    emit showHiddenChanged();

    update();
}

bool FileSystemModel::sortReverse() const {
    return m_sortReverse;
}

void FileSystemModel::setSortReverse(bool sortReverse) {
    if (m_sortReverse == sortReverse) {
        return;
    }

    m_sortReverse = sortReverse;
    emit sortReverseChanged();

    update();
}

FileSystemModel::Filters FileSystemModel::filter() const {
    return m_filter;
}

void FileSystemModel::setFilter(Filters filter) {
    if (m_filter == filter) {
        return;
    }

    m_filter = filter;
    emit filterChanged();

    update();
}

QStringList FileSystemModel::nameFilters() const {
    return m_nameFilters;
}

void FileSystemModel::setNameFilters(const QStringList& nameFilters) {
    if (m_nameFilters == nameFilters) {
        return;
    }

    m_nameFilters = nameFilters;
    emit nameFiltersChanged();

    update();
}

QQmlListProperty<FileSystemEntry> FileSystemModel::entries() {
    return { this, &m_entries };
}

void FileSystemModel::onDirChanged(const QString& dir) {
    m_pendingDirs.insert(dir);
    m_debounceTimer.start();
}

void FileSystemModel::processPendingDirs() {
    const auto dirs = std::exchange(m_pendingDirs, {});
    for (const auto& dir : dirs) {
        updateEntriesForDir(dir);
    }
}

void FileSystemModel::update() {
    m_pendingDirs.clear();
    updateWatcher();
    updateEntries();
}

void FileSystemModel::updateWatcher() {
    if (!m_watcher.directories().isEmpty()) {
        m_watcher.removePaths(m_watcher.directories());
    }

    if (!m_watchChanges || m_path.isEmpty()) {
        return;
    }

    if (!m_watcher.addPath(m_path))
        qWarning() << "FileSystemModel: failed to watch" << m_path;
}

void FileSystemModel::updateEntries() {
    if (m_path.isEmpty()) {
        if (!m_entries.isEmpty()) {
            beginResetModel();
            qDeleteAll(m_entries);
            m_entries.clear();
            endResetModel();
            emit entriesChanged();
        }

        return;
    }

    for (auto& future : m_futures) {
        future.cancel();
    }
    m_futures.clear();
    m_scanGenerations.clear();

    updateEntriesForDir(m_path);
}

void FileSystemModel::updateEntriesForDir(const QString& dir) {
    const auto recursive = m_recursive;
    const auto showHidden = m_showHidden;
    const auto filter = m_filter;
    const auto nameFilters = m_nameFilters;

    const bool isRoot = dir == m_path;
    const QString prefix = dir.endsWith(u'/') ? dir : dir + u'/';
    const auto currentDir = m_dir;
    const bool watchSubdirs = recursive && m_watchChanges;
    QSet<QString> oldPaths;
    for (const auto& entry : std::as_const(m_entries)) {
        if (isRoot || entry->path().startsWith(prefix))
            oldPaths << entry->path();
    }

    auto future = QtConcurrent::run([=](QPromise<PathDiff>& promise) {
        const auto flags = recursive ? QDirIterator::Subdirectories : QDirIterator::NoIteratorFlags;
        const auto scan = scanDir(dir, filtersFor(filter, nameFilters, showHidden), flags, watchSubdirs, promise);
        if (!scan)
            return;

        promise.addResult({ .removed = oldPaths - scan->paths, .added = scan->paths - oldPaths,
            .subdirs = scan->subdirs });
    });

    if (m_futures.contains(dir))
        m_futures[dir].cancel();
    m_futures.insert(dir, future);

    // An older scan finishing late must not untrack a newer scan of the same dir
    const auto generation = ++m_scanCounter;
    m_scanGenerations[dir] = generation;
    const auto untrack = [dir, generation, this] {
        if (m_scanGenerations.value(dir) != generation)
            return;
        m_futures.remove(dir);
        m_scanGenerations.remove(dir);
    };

    future
        .then(this,
            [untrack, currentDir, watchSubdirs, this](const PathDiff& result) {
                untrack();
                // New subdirectories surfaced by the same traversal; no second
                // scan. Ignore them when the model moved to another root.
                if (watchSubdirs && currentDir == m_dir && !result.subdirs.isEmpty()) {
                    const auto watched = m_watcher.directories();
                    QStringList fresh;
                    for (const auto& subdir : result.subdirs) {
                        if (!watched.contains(subdir))
                            fresh << subdir;
                    }
                    if (!fresh.isEmpty()) {
                        const auto failed = m_watcher.addPaths(fresh);
                        if (!failed.isEmpty())
                            qWarning() << "FileSystemModel: failed to watch" << failed.size() << "directories, e.g."
                                       << failed.first();
                    }
                }
                if (!result.removed.isEmpty() || !result.added.isEmpty())
                    applyChanges(result.removed, result.added);
            })
        .onCanceled(this, untrack);
}

FileSystemModel::ScanFilters FileSystemModel::filtersFor(
    Filters filter, const QStringList& nameFilters, bool showHidden) {
    ScanFilters filters;
    filters.nameFilters = nameFilters;

    const bool images = filter.testFlag(Filter::Images);
    const bool videos = filter.testFlag(Filter::Videos);
    const bool allFiles = filter.testFlag(Filter::Files);
    const bool dirs = filter.testFlag(Filter::Dirs);

    if (!allFiles && (images || videos)) {
        QSet<QString> imageExtensions;
        if (images) {
            const auto formats = QImageReader::supportedImageFormats();
            for (const auto& format : formats) {
                filters.nameFilters << u"*."_s + QString::fromUtf8(format);
                imageExtensions << QString::fromUtf8(format).toLower();
            }
        }

        QSet<QString> videoExtensions;
        QSet<QString> videoMimeTypes;
        if (videos) {
            // Windows: enumerate known video types, playback belongs to the OS.
#ifdef CAELESTIA_PORTABLE_UI
            const auto formats = QMimeDatabase().allMimeTypes();
            for (const auto& mimeType : formats) {
#else
            const auto formats = QMediaFormat().supportedFileFormats(QMediaFormat::Decode);
            for (const auto format : formats) {
                const auto mimeType = QMediaFormat(format).mimeType();
#endif
                if (!mimeType.name().startsWith(u"video/"_s))
                    continue;
                videoMimeTypes << mimeType.name();
                filters.nameFilters << mimeType.globPatterns();
                for (const auto& pattern : mimeType.globPatterns()) {
                    const auto dot = pattern.lastIndexOf(u'.');
                    if (dot >= 0)
                        videoExtensions << pattern.sliced(dot + 1).toLower();
                }
            }
        }

        // canRead()/mimeTypeForFile() both open the file; the extension gate
        // keeps that cost off files that cannot match anyway.
        filters.filterFn = [images, imageExtensions, videoExtensions,
                               videoMimeTypes](const QString& path, const QFileInfo& info) {
            const auto suffix = info.suffix().toLower();
            if (images && imageExtensions.contains(suffix) && QImageReader(path).canRead())
                return true;
            return !videoMimeTypes.isEmpty() && videoExtensions.contains(suffix)
                && videoMimeTypes.contains(QMimeDatabase().mimeTypeForFile(path).name());
        };
    }

    const bool files = allFiles || images || videos;
    if (!files && !dirs)
        filters.filters = QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot;
    if (files)
        filters.filters |= QDir::Files;
    if (dirs)
        filters.filters |= QDir::Dirs | QDir::NoDotAndDotDot;

    if (showHidden)
        filters.filters |= QDir::Hidden;

    return filters;
}

std::optional<FileSystemModel::ScanResult> FileSystemModel::scanDir(const QString& dir, const ScanFilters& filters,
    QDirIterator::IteratorFlags flags, bool collectDirs, const QPromise<PathDiff>& promise) {
    // Name filters are matched manually so the single traversal can collect
    // every subdirectory for the watcher; iterator-level name filters would
    // hide non-matching directories from the watch list.
    // The iterator itself must yield directories for that collection, so
    // widen the filter when watching; collected dirs are only reported to
    // the watcher, never added to the model unless the caller's own filter
    // already includes them.
    auto iterFilters = filters.filters;
    if (collectDirs)
        iterFilters |= QDir::Dirs | QDir::NoDotAndDotDot;
    QDirIterator iter(dir, iterFilters, flags);

    ScanResult result;
    while (iter.hasNext()) {
        if (promise.isCanceled())
            return std::nullopt;

        const QString path = iter.next();
        const QFileInfo info = iter.fileInfo();
        const bool isDir = info.isDir();
        if (collectDirs && isDir)
            result.subdirs << path;
        if (isDir && !filters.filters.testFlag(QDir::Dirs))
            continue;
        if (!filters.nameFilters.isEmpty() && !QDir::match(filters.nameFilters, info.fileName()))
            continue;
        if (filters.filterFn && !filters.filterFn(path, info))
            continue;

        result.paths.insert(path);
    }

    if (promise.isCanceled())
        return std::nullopt;

    return result;
}

void FileSystemModel::applyChanges(const QSet<QString>& removedPaths, const QSet<QString>& addedPaths) {
    QList<int> removedIndices;
    for (int i = 0; i < m_entries.size(); ++i) {
        if (removedPaths.contains(m_entries[i]->path())) {
            removedIndices << i;
        }
    }
    std::ranges::sort(removedIndices, std::greater<>());

    // Batch remove old entries
    int start = -1;
    int end = -1;
    for (const int idx : std::as_const(removedIndices)) {
        if (start == -1) {
            start = idx;
            end = idx;
        } else if (idx == end - 1) {
            end = idx;
        } else {
            beginRemoveRows(QModelIndex(), end, start);
            for (int i = start; i >= end; --i) {
                m_entries.takeAt(i)->deleteLater();
            }
            endRemoveRows();

            start = idx;
            end = idx;
        }
    }
    if (start != -1) {
        beginRemoveRows(QModelIndex(), end, start);
        for (int i = start; i >= end; --i) {
            m_entries.takeAt(i)->deleteLater();
        }
        endRemoveRows();
    }

    // Create new entries
    QSet<QString> existing;
    for (const auto& entry : std::as_const(m_entries))
        existing << entry->path();
    QList<FileSystemEntry*> newEntries;
    for (const auto& path : addedPaths) {
        if (!existing.contains(path))
            newEntries << new FileSystemEntry(path, m_dir.relativeFilePath(path), this);
    }
    std::ranges::sort(newEntries, [this](const FileSystemEntry* a, const FileSystemEntry* b) {
        return compareEntries(a, b);
    });

    // Batch insert new entries (each run lands contiguously before m_entries[row])
    int i = 0;
    while (i < newEntries.size()) {
        const auto it = std::ranges::lower_bound(
            m_entries, newEntries[i], [this](const FileSystemEntry* a, const FileSystemEntry* b) {
                return compareEntries(a, b);
            });
        const auto row = static_cast<int>(it - m_entries.begin());

        // Extend the run while the next new entry still sorts before the existing element at row
        int j = i + 1;
        while (j < newEntries.size() && (row >= m_entries.size() || compareEntries(newEntries[j], m_entries[row]))) {
            ++j;
        }

        beginInsertRows(QModelIndex(), row, row + (j - i) - 1);
        for (int k = i; k < j; ++k) {
            m_entries.insert(row + (k - i), newEntries[k]);
        }
        endInsertRows();

        i = j;
    }

    emit entriesChanged();
}

bool FileSystemModel::compareEntries(const FileSystemEntry* a, const FileSystemEntry* b) const {
    if (a->isDir() != b->isDir()) {
        return m_sortReverse ^ a->isDir();
    }
    const auto cmp = a->relativePath().localeAwareCompare(b->relativePath());
    return m_sortReverse ? cmp > 0 : cmp < 0;
}

} // namespace caelestia::shell::models
