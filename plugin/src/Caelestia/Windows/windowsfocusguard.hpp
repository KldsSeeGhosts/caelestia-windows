#pragma once

#include <qobject.h>
#include <qelapsedtimer.h>
#include <qpointer.h>
#include <qqmlintegration.h>
#include <qquickitem.h>
#include <qquickwindow.h>
#include <qstring.h>
#include <qtimer.h>
#include <qt_windows.h>

namespace caelestia::shell::windows {

// A local focus policy for the isolated Windows preview, not a focus grab.
// It never installs hooks, attaches input queues, or retries denied requests.
class WindowsFocusGuard : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(QQuickItem* target READ target WRITE setTarget NOTIFY targetChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(bool available READ available CONSTANT)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)

public:
    explicit WindowsFocusGuard(QObject* parent = nullptr);
    ~WindowsFocusGuard() override;

    [[nodiscard]] QQuickItem* target() const { return m_target.data(); }
    void setTarget(QQuickItem* target);

    [[nodiscard]] bool active() const { return m_active; }
    void setActive(bool active);

    [[nodiscard]] bool available() const { return true; }
    [[nodiscard]] QString status() const { return m_status; }

signals:
    void targetChanged();
    void activeChanged();
    void statusChanged();
    // Emitted for each result, even when the status text did not change.
    void outcome(const QString& status);
    // Reconcile foreground changes ignored by the backend's startup grace.
    void dismissRequested();

private:
    struct NativeWindow {
        HWND hwnd = nullptr;
        DWORD process = 0;
        DWORD thread = 0;
    };

    [[nodiscard]] static NativeWindow identify(HWND hwnd);
    [[nodiscard]] static NativeWindow identify(QQuickWindow* window);
    [[nodiscard]] static bool valid(const NativeWindow& window);
    void sampleExternalForeground();
    void bindWindow(QQuickWindow* window);
    void queueActivation(quint64 generation);
    void queueRestore(quint64 generation);
    void report(const QString& status, bool denied = false);

    QPointer<QQuickItem> m_target;
    QPointer<QQuickWindow> m_window;
    QMetaObject::Connection m_itemWindowConnection;
    QMetaObject::Connection m_itemDestroyedConnection;
    QMetaObject::Connection m_windowDestroyedConnection;
    QTimer m_pollTimer;
    QElapsedTimer m_activeAge;
    bool m_dismissSignaled = false;
    NativeWindow m_lastExternal;
    NativeWindow m_savedExternal;
    quint64 m_generation = 0;
    bool m_active = false;
    QString m_status = QStringLiteral("idle");
};

} // namespace caelestia::shell::windows
