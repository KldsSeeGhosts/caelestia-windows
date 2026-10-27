#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>

#include "focusfollowsmouse.hpp"

namespace caelestia::shell::windows {

// The shipped boundary: every read and write uses SystemParametersInfoW.
// Writes pass no SPIF_UPDATEINIFILE, so only this session's live values
// change and the user's stored X-Mouse preference is untouched.
class SystemParametersFocusFollowsMouse final: public FocusFollowsMouseSystem {
public:
    bool read(FocusFollowsMouseValues& values) override;
    bool setTracking(bool tracking) override;
    bool setDelayMs(int delayMs) override;
    bool setRaise(bool raise) override;
};

// QML element owned by a Loader in the Windows focus-follows-mouse facade.
// Constructing it touches nothing; the first apply() reads the current system
// values, and disabling or destroying it restores them. The Loader is only
// active while windows.focusFollowsMouse.enabled is true.
class WindowsFocusFollowsMouse: public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool applied READ applied NOTIFY stateChanged)
    Q_PROPERTY(QString status READ status NOTIFY stateChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY stateChanged)
    Q_PROPERTY(QString recoveryDirectory READ recoveryDirectory WRITE setRecoveryDirectory)

public:
    explicit WindowsFocusFollowsMouse(QObject* parent = nullptr);
    ~WindowsFocusFollowsMouse() override;

    [[nodiscard]] bool applied() const { return m_controller.active(); }
    [[nodiscard]] QString status() const { return m_status; }
    [[nodiscard]] QString lastError() const { return m_lastError; }
    [[nodiscard]] QString recoveryDirectory() const { return m_recoveryDirectory; }
    void setRecoveryDirectory(const QString& directory) { m_recoveryDirectory = directory; }

    Q_INVOKABLE bool apply(bool enabled, int delayMs, bool raise);
    Q_INVOKABLE void restore();

signals:
    void stateChanged();

private:
    void setState(const QString& status, const QString& error);

    SystemParametersFocusFollowsMouse m_system;
    FocusFollowsMouseController m_controller {m_system};
    QString m_status = QStringLiteral("idle");
    QString m_lastError;
    QString m_recoveryDirectory;
};

} // namespace caelestia::shell::windows
