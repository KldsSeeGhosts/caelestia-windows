#pragma once

#include <functional>
#include <memory>
#include <optional>
#include <qelapsedtimer.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qstringlist.h>
#include <qtimer.h>
#include <qvariantmap.h>

namespace caelestia::shell::windows {

struct CaptureIdentity {
    quint32 pid = 0;
    quint64 created = 0;
    quintptr window = 0;
    QString image;
    QString hostId;
    std::shared_ptr<void> handle;
};

struct CaptureProbe {
    enum Kind { Absent, Verified, Foreign, Uncertain } kind = Uncertain;
    CaptureIdentity identity;
};

struct CaptureStatus {
    bool valid = false;
    bool offline = false;
    QString hostId;
    QString phase;
};

// The only platform boundary. Status completion and exit observation must be
// asynchronous, context-bound, and must never enter a GUI-thread wait.
class CaptureHostOps {
public:
    virtual ~CaptureHostOps() = default;
    virtual CaptureProbe probe(const QString& image, const QString& windowClass) = 0;
    virtual bool matches(const CaptureIdentity& identity, const QString& windowClass) = 0;
    virtual bool hasCaptureWindow(const CaptureIdentity& identity) = 0;
    virtual bool postClose(const CaptureIdentity& identity) = 0;
    virtual bool launch(const QString& image, const QStringList& args, CaptureIdentity& child) = 0;
    virtual void status(const QString& image, QObject* context,
        std::function<void(CaptureStatus)> complete) = 0;
    virtual QObject* watch(const CaptureIdentity& identity, QObject* context,
        std::function<void()> exited) = 0;
    virtual std::optional<quint32> exitCode(const CaptureIdentity& identity) = 0;
};

std::shared_ptr<CaptureHostOps> makeCaptureHostOps();

class CaptureHostRegistry : public QObject {
    Q_OBJECT
public:
    explicit CaptureHostRegistry(std::shared_ptr<CaptureHostOps> ops, QObject* parent = nullptr);
    ~CaptureHostRegistry() override;
    quint64 acquire(const QString& image, const QString& windowClass, const QStringList& options);
    quint64 acquireCurrent();
    void release(quint64 lease);
    QVariantMap snapshot() const;
    bool command(quint64 lease, const QStringList& args);
    bool close(quint64 lease, bool restart = false);
    bool quit(quint64 lease);
    bool prepareReload(quint64 lease);
    void ensure(quint64 lease);
    // Short bounds in deterministic fixtures, unchanged production defaults.
    int closeTimeoutMs = 2000;
    int startupTimeoutMs = 20000;
    int recoveryDelayMs = 200;
    int stableWindowMs = 60000;
signals:
    void changed();
    void reloadReady(quint64 lease, bool ok);
    void quitReady(quint64 lease, bool ok);
private:
    bool writer(quint64 lease) const;
    bool verified();
    bool acceptStatus(const CaptureStatus& status);
    void setState(const QString& state, const QString& error = {});
    void inspect();
    void probeStartup();
    bool launch(const QStringList& args);
    void observe(const CaptureIdentity& identity);
    void stopWatching();
    void exited();
    void deadline();
    void check(std::function<void(bool)> complete);
    bool refuse(const QString& error);
    void completeReload(quint64 lease, bool ok);
    void completeQuit(bool ok);
    std::shared_ptr<CaptureHostOps> mOps;
    CaptureIdentity mIdentity;
    QObject* mWatch = nullptr;
    QTimer mDeadline;
    QString mState = QStringLiteral("Absent");
    QString mError;
    QString mImage;
    QString mClass;
    QStringList mOptions;
    QString mPhase;
    quint64 mSerial = 0;
    quint64 mLease = 0;
    quint64 mOperation = 0;
    quint64 mLaunchLease = 0;
    quint64 mReloadLease = 0;
    quint64 mQuitLease = 0;
    quint32 mLaunchedPid = 0;
    int mRecoveries = 0;
    quint64 mObservation = 0;
    QElapsedTimer mStableSince;
    bool mOwned = false;
    bool mLaunched = false;
    bool mWanted = true;
    bool mChecking = false;
    bool mCloseAttempted = false;
    bool mLaunchPending = false;
    bool mStartupExpired = false;
    bool mRestartAfterClose = false;
};

// Each QML generation gets a facade, not the process-global registry. Destroying
// a retired facade only releases its lease, never the process or a newer lease.
class CaptureHost : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantMap snapshot READ snapshot NOTIFY changed)
public:
    explicit CaptureHost(QObject* parent = nullptr);
    explicit CaptureHost(CaptureHostRegistry* registry, QObject* parent = nullptr);
    ~CaptureHost() override;
    QVariantMap snapshot() const;
    Q_INVOKABLE void acquire(const QString& image, const QString& windowClass, const QStringList& options);
    Q_INVOKABLE bool command(const QStringList& args);
    Q_INVOKABLE bool close(bool restart = false);
    Q_INVOKABLE bool quit();
    Q_INVOKABLE bool prepareReload();
signals:
    void changed();
    void reloadReady(bool ok);
    void quitReady(bool ok);
private:
    CaptureHostRegistry* mRegistry;
    quint64 mLease = 0;
};

} // namespace caelestia::shell::windows
