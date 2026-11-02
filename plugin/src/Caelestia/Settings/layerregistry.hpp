#pragma once

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qhash.h>
#include <qobject.h>
#include <qstringview.h>

#include "legacyreservation.hpp"
#include "node.hpp"

namespace caelestia::shell::settings {

// Derived from Node and has ctor(path, fallback, parent)
template <typename T>
concept LayerType = std::derived_from<T, Node> && std::constructible_from<T, const QString&, T*, QObject*>;

template <LayerType T> class LayerRegistry {
public:
    // screenNamesPath empty resolves the profile's screen-names.json. Fixtures
    // pass an explicit path so they never read or write the real profile.
    explicit LayerRegistry(
        const QString& prefix,
        const QString& suffix,
        QObject* parent,
        QString screenNamesPath = {}
    );

    [[nodiscard]] QString pathFor(const QString& name) const;
    [[nodiscard]] QString nameFor(T* layer) const;
    [[nodiscard]] T* get(const QString& name, T* fallback, bool* created = nullptr); // Created on demand

private:
    const QString m_prefix;
    const QString m_suffix;
    QObject* const m_parent;
    const QString m_screenNamesPath;
    QHash<QString, T*> m_layers;
    inline static int s_legacyCopyFailures = 0;
};

namespace detail {

inline QString stripTrailingSlashes(QStringView str) {
    while (str.endsWith(u'/'))
        str = str.left(str.length() - 1);
    return str.toString();
}

inline QString stripLeadingSlashes(QStringView str) {
    while (str.startsWith(u'/'))
        str = str.mid(1);
    return str.toString();
}

} // namespace detail

template <LayerType T>
LayerRegistry<T>::LayerRegistry(
    const QString& prefix,
    const QString& suffix,
    QObject* parent,
    QString screenNamesPath
)
    : m_prefix(detail::stripTrailingSlashes(prefix))
    , m_suffix(detail::stripLeadingSlashes(suffix))
    , m_parent(parent)
    , m_screenNamesPath(screenNamesPath.isEmpty() ? defaultScreenNamesPath() : screenNamesPath) {}

template <LayerType T> QString LayerRegistry<T>::pathFor(const QString& name) const {
    return m_prefix + u'/' + name + u'/' + m_suffix;
}

template <LayerType T> QString LayerRegistry<T>::nameFor(T* layer) const {
    return m_layers.key(layer);
}

template <LayerType T> T* LayerRegistry<T>::get(const QString& name, T* fallback, bool* created) {
    if (auto* const layer = m_layers.value(name)) {
        if (created)
            *created = false;
        return layer;
    }

    if (created)
        *created = true;

    const auto path = pathFor(name);
    QDir().mkpath(QFileInfo(path).absolutePath());
#ifdef Q_OS_WIN
    if (!QFileInfo::exists(path)) {
        // Explicit metadata only: a genuine label ending in " (2)" carries no
        // legacyLabel, so it can never pull another monitor's settings.
        const auto legacy = legacyLayerCopyFor(m_screenNamesPath, name, m_suffix);
        if (!legacy.legacyLabel.isEmpty() && !legacy.copied) {
            const auto legacyPath = pathFor(legacy.legacyLabel);
            if (QFileInfo(legacyPath).isFile()) {
                if (QFile::copy(legacyPath, path)) {
                    recordLegacyLayerCopied(m_screenNamesPath, name, m_suffix);
                } else {
                    ++s_legacyCopyFailures;
                    qCWarning(lcSettings)
                        << "Legacy per-monitor layer copy failed; total failures:" << s_legacyCopyFailures;
                }
            }
        }
    }
#endif

    auto* const layer = new T(path, fallback, m_parent);
    m_layers.insert(name, layer);
    return layer;
}

} // namespace caelestia::shell::settings
