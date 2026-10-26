#pragma once

#include <qobject.h>
#include <qqmlintegration.h>

namespace caelestia::shell::windows {

// Constructed by the Windows staging font loader, without native UI or input.
class WindowsFontFallback : public QObject {
    Q_OBJECT
    QML_ELEMENT

public:
    explicit WindowsFontFallback(QObject* parent = nullptr);
};

} // namespace caelestia::shell::windows
