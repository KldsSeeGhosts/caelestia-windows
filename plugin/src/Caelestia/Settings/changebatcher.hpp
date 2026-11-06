#pragma once

#include <qobject.h>

namespace caelestia::shell::settings {

class ChangeBatcher : public QObject {
    Q_OBJECT

public:
    explicit ChangeBatcher(QObject* parent = nullptr);

    void dirty();
    void flush(); // Emit dirtied now if there are queued changes

signals:
    void dirtied();

private:
    bool m_dirty;
};

} // namespace caelestia::shell::settings
