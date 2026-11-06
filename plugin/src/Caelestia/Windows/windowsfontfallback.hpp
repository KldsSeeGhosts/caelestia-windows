#pragma once

#include <qobject.h>
#include <qfont.h>
#include <qqmlintegration.h>

namespace caelestia::shell::windows {

// Explicit ordered families for the Windows-staged workspace label.
class WindowsFontFallback : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    using QObject::QObject;

    Q_INVOKABLE QFont workspaceFont(QFont font, const QString& primary) const;
};

} // namespace caelestia::shell::windows
