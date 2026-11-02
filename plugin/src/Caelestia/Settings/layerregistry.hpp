#pragma once

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qhash.h>
#include <qobject.h>
#include <qregularexpression.h>
#include <qstringview.h>

#include "node.hpp"

namespace caelestia::shell::settings {

// Derived from Node and has ctor(path, fallback, parent)
template <typename T>
concept LayerType = std::derived_from<T, Node> && std::constructible_from<T, const QString&, T*, QObject*>;

template <LayerType T> class LayerRegistry {
public:
    explicit LayerRegistry(const QString& prefix, const QString& suffix, QObject* parent);

    [[nodiscard]] QString pathFor(const QString& name) const;
    [[nodiscard]] QString nameFor(T* layer) const;
    [[nodiscard]] T* get(const QString& name, T* fallback, bool* created = nullptr); // Created on demand

private:
    const QString m_prefix;
    const QString m_suffix;
    QObject* const m_parent;
    QHash<QString, T*> m_layers;
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

// Windows gives each screen a unique name by adding " (2)", " (3)"... only
// when two friendly labels collide (see the backend ScreenIdentityRegistry).
// A screen that gained a suffix may have inherited the old, shared
// "monitors/<label>" directory. On first use, copy that legacy layer instead
// of overwriting or deleting it; the new layer then writes its own file. This
// leaves existing per-monitor settings working non-destructively.
inline QString legacyLayerName(const QString& name) {
    static const QRegularExpression suffix(QStringLiteral(" \\(([2-9]|[1-9][0-9]+)\\)$"));
    const auto match = suffix.match(name);
    if (!match.hasMatch())
        return {};
    return name.left(match.capturedStart()).trimmed();
}

} // namespace detail

template <LayerType T>
LayerRegistry<T>::LayerRegistry(const QString& prefix, const QString& suffix, QObject* parent)
    : m_prefix(detail::stripTrailingSlashes(prefix))
    , m_suffix(detail::stripLeadingSlashes(suffix))
    , m_parent(parent) {}

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
    if (!QFileInfo::exists(path)) {
        const auto legacy = detail::legacyLayerName(name);
        const auto legacyPath = legacy.isEmpty() ? QString() : pathFor(legacy);
        if (!legacyPath.isEmpty() && QFileInfo(legacyPath).isFile())
            QFile::copy(legacyPath, path);
    }

    auto* const layer = new T(path, fallback, m_parent);
    m_layers.insert(name, layer);
    return layer;
}

} // namespace caelestia::shell::settings
