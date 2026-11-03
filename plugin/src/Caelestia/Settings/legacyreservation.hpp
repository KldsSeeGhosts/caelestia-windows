#pragma once

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qjsonparseerror.h>
#include <qsavefile.h>
#include <qset.h>
#include <qstandardpaths.h>
#include <qstring.h>

namespace caelestia::shell::settings {

// Shared metadata written by the backend ScreenIdentityRegistry. A generated
// collision suffix records the plain label it was derived from exactly once;
// the registry copies that legacy layer and records completion here. Genuine
// labels (including labels that already end in " (2)") carry no legacyLabel,
// so no string inference is ever needed.
//
// Completion is recorded per layer, identified by its storage area and file:
// "config/shell.json", "state/persistent/state.json", "state/runtime/state.json".
// The file name alone is not enough, both state layers are called state.json.
struct LegacyLayerCopy {
    QString legacyLabel;
    bool copied = false;
};

inline QString legacyLayerKey(const QString& area, const QString& suffix) {
    return area + u'/' + suffix;
}

inline QString defaultScreenNamesPath() {
    auto isolated = qEnvironmentVariable("CAELESTIA_STATE_DIR");
    auto stateDir = isolated.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation) + QStringLiteral("/caelestia")
        : isolated;
    return stateDir + QStringLiteral("/screen-names.json");
}

// Empty when the file is missing, unreadable or malformed.
inline QJsonObject readReservations(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    QJsonParseError error;
    auto document = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject())
        return {};
    return document.object().value(QStringLiteral("reservations")).toObject();
}

inline LegacyLayerCopy
legacyLayerCopyFor(const QString& path, const QString& name, const QString& layerKey) {
    LegacyLayerCopy copy;
    const auto reservations = readReservations(path);
    for (auto it = reservations.begin(); it != reservations.end(); ++it) {
        const auto object = it.value().toObject();
        if (object.value(QStringLiteral("name")).toString().compare(name, Qt::CaseInsensitive) != 0)
            continue;
        copy.legacyLabel = object.value(QStringLiteral("legacyLabel")).toString();
        for (const auto& entry : object.value(QStringLiteral("legacyCopied")).toArray())
            if (entry.toString() == layerKey)
                copy.copied = true;
        break;
    }
    return copy;
}

enum class LegacyCopyResult {
    Recorded,   // Copied and recorded as complete.
    CopyFailed, // The file could not be copied; nothing was recorded.
    Unrecorded, // The completion record could not be committed (see below).
};

namespace detail {

// Layers whose completion could not be recorded in this process. A copy that
// cannot be recorded would otherwise be repeated every time the destination is
// missing again.
inline QSet<QString>& unrecordedLegacyCopies() {
    static QSet<QString> keys;
    return keys;
}

} // namespace detail

// Copies legacyPath to destPath and records completion for (name, layerKey) as
// one step. The record is opened for writing before the copy, so a record that
// cannot be written never follows a copy, and it is committed after it. If it
// cannot be committed the copy stays in place and the failure is remembered for
// this session, so the copy is not repeated. An unreadable or malformed record
// is never overwritten.
inline LegacyCopyResult copyLegacyLayerOnce(
    const QString& metadataPath,
    const QString& name,
    const QString& layerKey,
    const QString& legacyPath,
    const QString& destPath
) {
    const auto token = metadataPath + u'|' + layerKey + u'|' + name.toCaseFolded();
    auto& unrecorded = detail::unrecordedLegacyCopies();
    if (unrecorded.contains(token))
        return LegacyCopyResult::Unrecorded;

    QSaveFile record(metadataPath);
    if (!record.open(QIODevice::WriteOnly)) {
        unrecorded.insert(token);
        return LegacyCopyResult::Unrecorded;
    }

    if (!QFile::copy(legacyPath, destPath)) {
        record.cancelWriting();
        return LegacyCopyResult::CopyFailed;
    }

    // Read the record only now, so a concurrent update by the backend between
    // the check and the copy is merged rather than overwritten.
    auto root = QJsonObject();
    auto readable = false;
    {
        QFile file(metadataPath);
        QJsonParseError error;
        if (file.open(QIODevice::ReadOnly)) {
            auto document = QJsonDocument::fromJson(file.readAll(), &error);
            readable = error.error == QJsonParseError::NoError && document.isObject();
            if (readable)
                root = document.object();
        }
    }
    auto reservations = root.value(QStringLiteral("reservations")).toObject();
    auto recorded = false;
    for (auto it = reservations.begin(); readable && it != reservations.end(); ++it) {
        auto object = it.value().toObject();
        if (object.value(QStringLiteral("name")).toString().compare(name, Qt::CaseInsensitive) != 0)
            continue;
        auto copied = object.value(QStringLiteral("legacyCopied")).toArray();
        auto found = false;
        for (const auto& entry : copied)
            found = found || entry.toString() == layerKey;
        if (!found)
            copied.append(layerKey);
        object.insert(QStringLiteral("legacyCopied"), copied);
        it.value() = object;
        recorded = true;
        break;
    }

    if (recorded) {
        root.insert(QStringLiteral("reservations"), reservations);
        record.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
        recorded = record.commit();
    } else {
        record.cancelWriting();
    }

    if (!recorded) {
        unrecorded.insert(token);
        return LegacyCopyResult::Unrecorded;
    }
    return LegacyCopyResult::Recorded;
}

} // namespace caelestia::shell::settings
