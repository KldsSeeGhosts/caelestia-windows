#pragma once

#include <qobject.h>
#include <qpointer.h>
#include <qqmlintegration.h>
#include <qquickitem.h>
#include <qquickwindow.h>
#include <qstring.h>
#include <qtmetamacros.h>
#include <qt_windows.h>

namespace caelestia::shell::windows {

// A local focus policy for the isolated Windows preview, not a focus grab.
// It never installs hooks, attaches input queues, or retries denied requests.
// Foreground changes arrive from the backend's event-driven observer; this
// class holds no timer and never samples the foreground on a schedule.
class WindowsFocusGuard : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QQuickItem* target READ target WRITE setTarget NOTIFY targetChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(QObject* foregroundSource READ foregroundSource WRITE setForegroundSource
                   NOTIFY foregroundSourceChanged)
    Q_PROPERTY(bool available READ available CONSTANT)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)

public:
    explicit WindowsFocusGuard(QObject* parent = nullptr);
    ~WindowsFocusGuard() override;

    [[nodiscard]] QQuickItem* target() const { return m_target.data(); }
    void setTarget(QQuickItem* target);

    [[nodiscard]] bool active() const { return m_active; }
    void setActive(bool active);

    // A Quickshell.Windows.Foreground instance, or any object with a
    // foregroundChanged(qulonglong hwnd, uint time) signal carrying the tick
    // count of the EVENT_SYSTEM_FOREGROUND that produced the change.
    [[nodiscard]] QObject* foregroundSource() const { return m_foregroundSource.data(); }
    void setForegroundSource(QObject* source);

    [[nodiscard]] bool available() const { return true; }
    [[nodiscard]] QString status() const { return m_status; }

signals:
    void targetChanged();
    void activeChanged();
    void foregroundSourceChanged();
    void statusChanged();
    // Emitted for each result, even when the status text did not change.
    void outcome(const QString& status);
    // The user gave the foreground to another application or the desktop.
    void dismissRequested();

private slots:
    void onForegroundChanged(qulonglong hwnd, uint time);

private:
    struct NativeWindow {
        HWND hwnd = nullptr;
        DWORD process = 0;
        DWORD thread = 0;
    };

    [[nodiscard]] static NativeWindow identify(HWND hwnd);
    [[nodiscard]] static NativeWindow identify(QQuickWindow* window);
    [[nodiscard]] static bool valid(const NativeWindow& window);
    [[nodiscard]] static bool notBefore(DWORD time, DWORD reference);
    void sampleExternalForeground();
    void bindWindow(QQuickWindow* window);
    void queueActivation(quint64 generation);
    void queueRestore(quint64 generation);
    void report(const QString& status, bool denied = false);

    QPointer<QQuickItem> m_target;
    QPointer<QQuickWindow> m_window;
    QPointer<QObject> m_foregroundSource;
    QMetaObject::Connection m_itemWindowConnection;
    QMetaObject::Connection m_itemDestroyedConnection;
    QMetaObject::Connection m_windowDestroyedConnection;
    QMetaObject::Connection m_foregroundConnection;
    DWORD m_activatedAt = 0;
    bool m_dismissSignaled = false;
    NativeWindow m_lastExternal;
    NativeWindow m_savedExternal;
    quint64 m_generation = 0;
    bool m_active = false;
    QString m_status = QStringLiteral("idle");
};

} // namespace caelestia::shell::windows
