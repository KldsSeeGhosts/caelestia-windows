#pragma once

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qsavefile.h>
#include <qstandardpaths.h>
#include <qstring.h>

namespace caelestia::shell::settings {

// Shared metadata written by the backend ScreenIdentityRegistry. A generated
// collision suffix records the plain label it was derived from exactly once;
// the registry copies that legacy layer and records completion here. Genuine
// labels (including labels that already end in " (2)") carry no legacyLabel,
// so no string inference is ever needed.
struct LegacyLayerCopy {
    QString legacyLabel;
    bool copied = false;
};

inline QString defaultScreenNamesPath() {
    auto isolated = qEnvironmentVariable("CAELESTIA_STATE_DIR");
    auto stateDir = isolated.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation) + QStringLiteral("/caelestia")
        : isolated;
    return stateDir + QStringLiteral("/screen-names.json");
}

inline QJsonObject readReservations(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    auto document = QJsonDocument::fromJson(file.readAll());
    if (!document.isObject())
        return {};
    return document.object().value(QStringLiteral("reservations")).toObject();
}

inline LegacyLayerCopy
legacyLayerCopyFor(const QString& path, const QString& name, const QString& suffix) {
    LegacyLayerCopy copy;
    const auto reservations = readReservations(path);
    for (auto it = reservations.begin(); it != reservations.end(); ++it) {
        const auto object = it.value().toObject();
        if (object.value(QStringLiteral("name")).toString().compare(name, Qt::CaseInsensitive) != 0)
            continue;
        copy.legacyLabel = object.value(QStringLiteral("legacyLabel")).toString();
        for (const auto& entry : object.value(QStringLiteral("legacyCopied")).toArray())
            if (entry.toString() == suffix)
                copy.copied = true;
        break;
    }
    return copy;
}

inline void
recordLegacyLayerCopied(const QString& path, const QString& name, const QString& suffix) {
    auto document = QJsonDocument();
    {
        QFile file(path);
        if (file.open(QIODevice::ReadOnly))
            document = QJsonDocument::fromJson(file.readAll());
    }
    auto root = document.isObject() ? document.object() : QJsonObject();
    auto reservations = root.value(QStringLiteral("reservations")).toObject();

    for (auto it = reservations.begin(); it != reservations.end(); ++it) {
        auto object = it.value().toObject();
        if (object.value(QStringLiteral("name")).toString().compare(name, Qt::CaseInsensitive) != 0)
            continue;
        auto copied = object.value(QStringLiteral("legacyCopied")).toArray();
        auto found = false;
        for (const auto& entry : copied)
            found = found || entry.toString() == suffix;
        if (!found)
            copied.append(suffix);
        object.insert(QStringLiteral("legacyCopied"), copied);
        it.value() = object;
        break;
    }

    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("reservations"), reservations);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return;
    file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    file.commit();
}

} // namespace caelestia::shell::settings
