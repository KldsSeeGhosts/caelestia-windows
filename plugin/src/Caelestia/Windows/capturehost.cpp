#include "capturehost.hpp"

#include <windows.h>
#include <qcoreapplication.h>
#include <qdir.h>
#include <qfileinfo.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qpointer.h>
#include <qprocess.h>
#include <qwineventnotifier.h>
#include <utility>

namespace caelestia::shell::windows {
namespace {
bool sameImage(const QString& a, const QString& b) {
    if (a.isEmpty() || b.isEmpty())
        return false;
    // Resolve filesystem aliases before comparison, but never use a basename.
    const auto ca = QFileInfo(a).canonicalFilePath();
    const auto cb = QFileInfo(b).canonicalFilePath();
    return !ca.isEmpty() && !cb.isEmpty() && ca.compare(cb, Qt::CaseInsensitive) == 0;
}

quint64 creation(HANDLE process) {
    FILETIME created{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(process, &created, &exit, &kernel, &user))
        return 0;
    return (quint64(created.dwHighDateTime) << 32) | created.dwLowDateTime;
}

QString imagePath(HANDLE process) {
    wchar_t path[32768];
    DWORD length = DWORD(std::size(path));
    return QueryFullProcessImageNameW(process, 0, path, &length)
        ? QString::fromWCharArray(path, int(length)) : QString();
}

QString quotedArgument(const QString& value) {
    // Windows CommandLineToArgvW / CRT quoting, including trailing slashes.
    QString result(QLatin1Char('"'));
    int slashes = 0;
    for (const auto ch : value) {
        if (ch == QLatin1Char('\\')) {
            ++slashes;
            continue;
        }
        result += QString(slashes * (ch == QLatin1Char('"') ? 2 : 1), QLatin1Char('\\'));
        slashes = 0;
        if (ch == QLatin1Char('"'))
            result += QLatin1Char('\\');
        result += ch;
    }
    result += QString(slashes * 2, QLatin1Char('\\'));
    result += QLatin1Char('"');
    return result;
}

class WindowsCaptureHostOps final : public CaptureHostOps {
public:
    CaptureProbe probe(const QString& image, const QString& windowClass) override {
        const auto window = FindWindowW(reinterpret_cast<LPCWSTR>(windowClass.utf16()), nullptr);
        if (!window)
            return {CaptureProbe::Absent, {}};
        DWORD pid = 0;
        GetWindowThreadProcessId(window, &pid);
        if (!pid)
            return {};
        HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!process)
            return {};
        CaptureIdentity identity;
        identity.handle = std::shared_ptr<void>(process, [](void* h) { CloseHandle(h); });
        identity.pid = pid;
        identity.created = creation(process);
        identity.image = imagePath(process);
        identity.window = reinterpret_cast<quintptr>(window);
        if (!identity.created || identity.image.isEmpty())
            return {};
        if (!sameImage(identity.image, image))
            return {CaptureProbe::Foreign, identity};
        return matches(identity, windowClass)
            ? CaptureProbe{CaptureProbe::Verified, identity} : CaptureProbe{};
    }

    bool matches(const CaptureIdentity& identity, const QString& windowClass) override {
        if (!identity.handle || !identity.created)
            return false;
        DWORD code = 0;
        const auto process = identity.handle.get();
        if (!GetExitCodeProcess(process, &code) || code != STILL_ACTIVE
            || creation(process) != identity.created || !sameImage(imagePath(process), identity.image))
            return false;
        const auto window = reinterpret_cast<HWND>(identity.window);
        DWORD pid = 0;
        GetWindowThreadProcessId(window, &pid);
        wchar_t name[256]{};
        if (!GetClassNameW(window, name, int(std::size(name))))
            return false;
        return pid == identity.pid && QString::fromWCharArray(name) == windowClass
            && FindWindowW(reinterpret_cast<LPCWSTR>(windowClass.utf16()), nullptr) == window;
    }

    bool hasCaptureWindow(const CaptureIdentity& identity) override {
        // Protocol v1 reports recording selection, but not the screenshot
        // editor. Refuse close while any other visible window of this verified
        // process exists. Conservative refusal is preferable to lost work.
        struct Context { quint32 pid; bool busy; } context{identity.pid, false};
        EnumWindows([](HWND window, LPARAM value) -> BOOL {
            auto& context = *reinterpret_cast<Context*>(value);
            DWORD pid = 0;
            GetWindowThreadProcessId(window, &pid);
            if (pid == context.pid && IsWindowVisible(window))
                context.busy = true;
            return TRUE;
        }, reinterpret_cast<LPARAM>(&context));
        return context.busy;
    }

    bool postClose(const CaptureIdentity& identity) override {
        return PostMessageW(reinterpret_cast<HWND>(identity.window), WM_CLOSE, 0, 0) != FALSE;
    }

    bool launch(const QString& image, const QStringList& args, CaptureIdentity& child) override {
        if (!QFileInfo(image).isAbsolute())
            return false;
        auto command = quotedArgument(QDir::toNativeSeparators(image));
        for (const auto& arg : args)
            command += QLatin1Char(' ') + quotedArgument(arg);
        // The image and all supplied file paths are absolute. Do not pin a
        // retired payload as cwd for the lifetime of the capture host.
        const auto directory = QDir::toNativeSeparators(QDir::homePath());
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};
        // No inherited handles, console, stdio, focus request or GUI wait.
        // Keep the creation handle itself, avoiding OpenProcess/PID-reuse races
        // even if a failed startup or forwarding client exits immediately.
        if (!CreateProcessW(reinterpret_cast<LPCWSTR>(image.utf16()),
            reinterpret_cast<LPWSTR>(command.data()), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW, nullptr, reinterpret_cast<LPCWSTR>(directory.utf16()), &startup, &process))
            return false;
        CloseHandle(process.hThread);
        child.handle = std::shared_ptr<void>(process.hProcess, [](void* h) { CloseHandle(h); });
        child.pid = process.dwProcessId;
        child.created = creation(process.hProcess);
        child.image = imagePath(process.hProcess);
        return true;
    }

    void status(const QString& image, QObject* context,
        std::function<void(CaptureStatus)> complete) override {
        auto* process = new QProcess(context);
        auto* timeout = new QTimer(process);
        timeout->setSingleShot(true);
        auto done = std::make_shared<bool>(false);
        auto finish = [process, done, complete](CaptureStatus status) {
            if (!std::exchange(*done, true))
                complete(status);
            // Never destroy a running QProcess: its destructor waits.
            if (process->state() == QProcess::NotRunning)
                process->deleteLater();
        };
        QObject::connect(process, &QProcess::finished, process, [process, finish](int, QProcess::ExitStatus) {
            CaptureStatus status;
            const auto data = QJsonDocument::fromJson(process->readAllStandardOutput()).object();
            if (data.value(QStringLiteral("version")).toInt() == 1
                && data.value(QStringLiteral("ok")).isBool()) {
                status.offline = !data.value(QStringLiteral("ok")).toBool()
                    && data.value(QStringLiteral("host_id")).toString().isEmpty();
                status.hostId = data.value(QStringLiteral("host_id")).toString();
                status.phase = data.value(QStringLiteral("state")).toString();
                status.valid = data.value(QStringLiteral("ok")).toBool()
                    && !status.hostId.isEmpty()
                    && QStringList{QStringLiteral("idle"), QStringLiteral("selecting"), QStringLiteral("ready"),
                        QStringLiteral("recording"), QStringLiteral("paused"), QStringLiteral("finalizing")}.contains(status.phase);
            }
            finish(status);
        });
        QObject::connect(process, &QProcess::errorOccurred, process, [finish](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart)
                finish({});
        });
        QObject::connect(timeout, &QTimer::timeout, process, [process, finish] {
            // Only this short-lived status client, never the host.
            process->kill();
            finish({});
        });
        process->setProgram(image);
        process->setArguments({QStringLiteral("--status")});
        process->setWorkingDirectory(QDir::homePath());
        process->setStandardErrorFile(QProcess::nullDevice());
        timeout->start(16000);
        process->start();
    }

    QObject* watch(const CaptureIdentity& identity, QObject* context,
        std::function<void()> exited) override {
        auto* notifier = new QWinEventNotifier(identity.handle.get(), context);
        QObject::connect(notifier, &QWinEventNotifier::activated, notifier, [notifier, exited] {
            notifier->setEnabled(false);
            exited();
        });
        return notifier;
    }

    std::optional<quint32> exitCode(const CaptureIdentity& identity) override {
        DWORD code = 0;
        if (!identity.handle || !GetExitCodeProcess(identity.handle.get(), &code) || code == STILL_ACTIVE)
            return std::nullopt;
        return code;
    }
};
}

std::shared_ptr<CaptureHostOps> makeCaptureHostOps() {
    return std::make_shared<WindowsCaptureHostOps>();
}

CaptureHostRegistry::CaptureHostRegistry(std::shared_ptr<CaptureHostOps> ops, QObject* parent)
    : QObject(parent), mOps(std::move(ops)) {
    mDeadline.setSingleShot(true);
    connect(&mDeadline, &QTimer::timeout, this, &CaptureHostRegistry::deadline);
}

CaptureHostRegistry::~CaptureHostRegistry() {
    // QObject destroys children after members. A threadpool wait must be
    // unregistered before the member holding its HANDLE can be destroyed.
    stopWatching();
}

bool CaptureHostRegistry::writer(quint64 lease) const { return lease && lease == mLease; }

void CaptureHostRegistry::setState(const QString& state, const QString& error) {
    if (state == QStringLiteral("Owned") && !mStableSince.isValid())
        mStableSince.start();
    mState = state;
    mError = error;
    emit changed();
}

QVariantMap CaptureHostRegistry::snapshot() const {
    return {{QStringLiteral("state"), mState}, {QStringLiteral("error"), mError},
        {QStringLiteral("owned"), mOwned},
        {QStringLiteral("launched"), mLaunched && mLaunchLease == mLease && mState == QStringLiteral("Owned")},
        {QStringLiteral("pid"), mIdentity.pid}, {QStringLiteral("hostId"), mIdentity.hostId},
        {QStringLiteral("phase"), mPhase}, {QStringLiteral("checking"), mChecking},
        {QStringLiteral("closeAttempted"), mCloseAttempted},
        {QStringLiteral("recoveries"), mRecoveries}};
}

quint64 CaptureHostRegistry::acquireCurrent() {
    completeReload(mReloadLease, false);
    completeQuit(false);
    mLease = ++mSerial;
    return mLease;
}

quint64 CaptureHostRegistry::acquire(const QString& image, const QString& windowClass, const QStringList& options) {
    acquireCurrent();
    // A different payload is never silently adopted by soft reload. Installation
    // replacement uses full quit/Stop-CaelestiaHosts, not this handoff.
    const bool changedPayload = !mImage.isEmpty() && (!sameImage(image, mImage) || windowClass != mClass);
    if (changedPayload) {
        ++mOperation;
        mChecking = false;
        if (!mCloseAttempted)
            mDeadline.stop();
    }
    if (mIdentity.handle && changedPayload) {
        mImage = image;
        mClass = windowClass;
        mOptions = options;
        mWanted = false; // Never recover the retired payload after its exit.
        mOwned = false;
        mStableSince.invalidate();
        setState(mCloseAttempted ? mState : QStringLiteral("Foreign"),
            QStringLiteral("Capture host belongs to another payload; retained for exit observation only."));
        return mLease;
    }
    mImage = image;
    mClass = windowClass;
    mOptions = options;
    emit changed();
    ensure(mLease);
    return mLease;
}

void CaptureHostRegistry::release(quint64 lease) {
    if (writer(lease))
        mLease = 0;
}

bool CaptureHostRegistry::verified() {
    return mIdentity.handle && sameImage(mImage, mIdentity.image) && mOps->matches(mIdentity, mClass);
}

bool CaptureHostRegistry::acceptStatus(const CaptureStatus& status) {
    if (!status.valid || !verified()
        || !status.hostId.startsWith(QString::number(mIdentity.pid) + QLatin1Char('-'))
        || (!mIdentity.hostId.isEmpty() && status.hostId != mIdentity.hostId))
        return false;
    mIdentity.hostId = status.hostId;
    mPhase = status.phase;
    return true;
}

void CaptureHostRegistry::observe(const CaptureIdentity& identity) {
    stopWatching();
    const bool sameProcess = mIdentity.pid == identity.pid && mIdentity.created == identity.created;
    const auto hostId = sameProcess ? mIdentity.hostId : QString();
    if (!sameProcess)
        mStableSince.invalidate();
    mIdentity = identity;
    mIdentity.hostId = hostId;
    mLaunched = mLaunchedPid != 0 && mLaunchedPid == identity.pid;
    const auto observation = ++mObservation;
    mWatch = mOps->watch(mIdentity, this, [this, observation] {
        if (observation == mObservation)
            exited();
    });
}

void CaptureHostRegistry::stopWatching() {
    ++mObservation;
    if (auto* notifier = qobject_cast<QWinEventNotifier*>(mWatch))
        notifier->setEnabled(false);
    delete mWatch;
    mWatch = nullptr;
}

bool CaptureHostRegistry::refuse(const QString& error) {
    mError = error;
    emit changed();
    return false;
}

void CaptureHostRegistry::ensure(quint64 lease) {
    if (!writer(lease) || mChecking || !mWanted || mCloseAttempted)
        return;
    if (mLaunchPending) {
        mStartupExpired = false;
        mDeadline.start(startupTimeoutMs);
        probeStartup();
        return;
    }
    if (mIdentity.handle) {
        if (mState != QStringLiteral("Owned"))
            check([](bool) {});
        return;
    }
    inspect();
}

void CaptureHostRegistry::inspect() {
    mChecking = true;
    setState(QStringLiteral("Probing"));
    const auto operation = ++mOperation;
    mOps->status(mImage, this, [this, operation](CaptureStatus status) {
        if (operation != mOperation)
            return;
        mChecking = false;
        const auto probe = mOps->probe(mImage, mClass);
        if (probe.kind == CaptureProbe::Absent && status.offline) {
            setState(QStringLiteral("Absent"));
            if (mLease && mWanted)
                launch(mOptions);
        } else if (probe.kind == CaptureProbe::Verified) {
            observe(probe.identity);
            mOwned = true;
            if (acceptStatus(status))
                setState(QStringLiteral("Owned"));
            else
                setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host status could not be verified."));
        } else {
            mOwned = false;
            if (probe.identity.handle)
                observe(probe.identity); // Observe Foreign, never claim it.
            setState(probe.kind == CaptureProbe::Foreign ? QStringLiteral("Foreign") : QStringLiteral("CloseFailed"),
                QStringLiteral("Capture host identity is foreign or inaccessible; no process was changed."));
        }
    });
}

bool CaptureHostRegistry::launch(const QStringList& args) {
    if (mIdentity.handle || mCloseAttempted || mLaunchPending) {
        setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host identity is still retained; launch refused."));
        return false;
    }
    mLaunchLease = mLease;
    mLaunchedPid = 0;
    CaptureIdentity child;
    if (!mOps->launch(mImage, args, child)) {
        setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host launch failed."));
        return false;
    }
    mLaunchedPid = child.pid;
    mLaunchPending = true;
    mStartupExpired = false;
    mOwned = bool(child.handle); // CreateProcess handle, not a class-only claim.
    if (child.handle)
        observe(child);
    setState(QStringLiteral("Starting"));
    mDeadline.start(startupTimeoutMs);
    probeStartup();
    return true;
}

void CaptureHostRegistry::probeStartup() {
    // Bounded asynchronous startup observations. A deadline is not evidence
    // that the launched process died, so it never permits a duplicate launch.
    mChecking = true;
    const auto operation = ++mOperation;
    mOps->status(mImage, this, [this, operation](CaptureStatus status) {
        if (operation != mOperation)
            return;
        mChecking = false;
        if (!mLaunchPending || mCloseAttempted)
            return;
        const auto probe = mOps->probe(mImage, mClass);
        if (probe.kind == CaptureProbe::Verified) {
            if (mIdentity.handle && (probe.identity.pid != mIdentity.pid
                || probe.identity.created != mIdentity.created)) {
                // Our launched client forwarded to somebody else. Keep the
                // actual host identity, but do not grant journal freshness.
                mLaunchedPid = 0;
            }
            observe(probe.identity);
            mOwned = true;
            if (acceptStatus(status)) {
                mLaunchPending = false;
                mDeadline.stop();
                setState(QStringLiteral("Owned"));
                return;
            }
        } else if (probe.kind == CaptureProbe::Foreign && !mIdentity.handle) {
            observe(probe.identity);
            mOwned = false;
        }
        // Retain startup uncertainty and its deadline, never claim launch from
        // the lifetime of a forwarding command client.
        emit changed();
        QTimer::singleShot(100, this, [this, operation] {
            if (operation == mOperation && mLaunchPending && !mStartupExpired && !mChecking)
                probeStartup();
        });
    });
}

void CaptureHostRegistry::check(std::function<void(bool)> complete) {
    mChecking = true;
    mError.clear();
    emit changed();
    const auto operation = ++mOperation;
    mOps->status(mImage, this, [this, operation, complete](CaptureStatus status) {
        if (operation != mOperation)
            return;
        mChecking = false;
        const auto probe = mOps->probe(mImage, mClass);
        if (probe.kind == CaptureProbe::Verified && mIdentity.handle
            && probe.identity.pid == mIdentity.pid && probe.identity.created == mIdentity.created
            && sameImage(probe.identity.image, mIdentity.image)
            && (probe.identity.window == mIdentity.window || (mLaunchPending && !mIdentity.window)))
            observe(probe.identity);
        const bool ok = acceptStatus(status);
        if (!ok) {
            mStableSince.invalidate();
            setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host health/identity could not be verified."));
        } else {
            mOwned = true;
            mLaunchPending = false;
            mDeadline.stop();
            setState(QStringLiteral("Owned"));
        }
        complete(ok);
    });
}

bool CaptureHostRegistry::command(quint64 lease, const QStringList& args) {
    if (writer(lease) && !mChecking && !mIdentity.handle && !mCloseAttempted
        && (mState == QStringLiteral("Absent") || mState == QStringLiteral("Exited"))) {
        mWanted = true;
        mRecoveries = 0; // Cold launch is not a crash recovery.
        return launch(args);
    }
    if (!writer(lease))
        return false;
    if (mChecking || mCloseAttempted)
        return refuse(QStringLiteral("Capture command refused: host operation is pending."));
    if (mState != QStringLiteral("Owned") || !verified()) {
        if (mIdentity.handle) {
            // A single bounded recheck can revive a slow startup, restored
            // access or transient status failure. Never replace a retained PID.
            check([](bool) {});
        } else {
            mWanted = true;
            mRecoveries = 0;
            inspect();
        }
        return false; // Re-verification requested, command not yet delivered.
    }
    CaptureIdentity forwardingClient;
    // Forwarding to an existing host never grants launchedHost freshness.
    const bool sent = mOps->launch(mImage, args, forwardingClient);
    if (sent) {
        mWanted = true;
        mRecoveries = 0;
    }
    return sent;
}

bool CaptureHostRegistry::close(quint64 lease, bool restart) {
    if (!writer(lease))
        return false;
    if (mChecking || mCloseAttempted)
        return refuse(QStringLiteral("Capture host close refused: host operation is pending."));
    if (mState == QStringLiteral("Absent") || mState == QStringLiteral("Exited")) {
        mWanted = restart;
        if (restart) {
            mRecoveries = 0;
            ensure(lease);
        }
        return true;
    }
    if (!mOwned || !mIdentity.handle)
        return refuse(QStringLiteral("Capture host close refused: no owned identity."));
    check([this, lease, restart](bool ok) {
        if (!writer(lease)) {
            mError = QStringLiteral("Capture host close superseded by a newer generation.");
            emit changed();
            completeQuit(false);
            return;
        }
        if (!ok || mPhase != QStringLiteral("idle") || mOps->hasCaptureWindow(mIdentity)) {
            if (ok)
                mError = QStringLiteral("Capture host close refused: capture or recording is active.");
            emit changed();
            completeQuit(false);
            return;
        }
        if (!verified() || !mOps->postClose(mIdentity)) {
            setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host close could not be posted; ownership retained."));
            completeQuit(false);
            return;
        }
        mWanted = restart;
        mRestartAfterClose = restart;
        if (restart)
            mRecoveries = 0;
        mCloseAttempted = true; // Only a genuinely posted close blocks reload.
        setState(QStringLiteral("Closing"));
        mDeadline.start(closeTimeoutMs);
    });
    return true; // Accepted for asynchronous checking, not completion.
}

bool CaptureHostRegistry::quit(quint64 lease) {
    if (!writer(lease))
        return false;
    if (mOwned || mCloseAttempted) {
        mQuitLease = lease;
        const bool accepted = close(lease);
        if (!accepted)
            completeQuit(false);
        return accepted;
    }
    // No owned identity to close. Cancel pending discovery so it cannot launch
    // a new host after shell quit has been accepted. Foreign observation is
    // retained until destruction, without posting anything to that process.
    ++mOperation;
    mWanted = false;
    mChecking = false;
    mDeadline.stop();
    emit changed();
    return true;
}

bool CaptureHostRegistry::prepareReload(quint64 lease) {
    if (!writer(lease))
        return false;
    if (mQuitLease)
        return refuse(QStringLiteral("Capture handoff refused: shell quit is pending."));
    if (mCloseAttempted)
        return refuse(QStringLiteral("Capture handoff refused: a posted close is unresolved."));
    // No native ownership or process lifetime is changed by QML reload.
    // Preserve even uncertain observations and in-flight checks across graphs.
    mReloadLease = lease;
    QTimer::singleShot(0, this, [this, lease] {
        if (mQuitLease)
            refuse(QStringLiteral("Capture handoff refused: shell quit is pending."));
        else if (mCloseAttempted)
            refuse(QStringLiteral("Capture handoff refused: a posted close is unresolved."));
        completeReload(lease, writer(lease) && !mCloseAttempted && !mQuitLease);
    });
    return true;
}

void CaptureHostRegistry::completeReload(quint64 lease, bool ok) {
    if (!lease || lease != mReloadLease)
        return;
    mReloadLease = 0;
    emit reloadReady(lease, ok);
}

void CaptureHostRegistry::completeQuit(bool ok) {
    const auto lease = std::exchange(mQuitLease, 0);
    if (lease)
        emit quitReady(lease, ok);
}

void CaptureHostRegistry::deadline() {
    // Startup timeout is nonterminal. Accept a healthy response already in
    // flight (the production status client itself is bounded to 16 seconds).
    // Stop automatic polling, with explicit command/close/ensure able to retry.
    if (mLaunchPending)
        mStartupExpired = true;
    setState(QStringLiteral("CloseFailed"),
        QStringLiteral("Capture host deadline missed; exit is unconfirmed and ownership retained."));
    if (mCloseAttempted) {
        completeQuit(false);
        completeReload(mReloadLease, false);
    }
}

void CaptureHostRegistry::exited() {
    const auto code = mOps->exitCode(mIdentity);
    const bool crashed = mOwned && code && *code != 0;
    const bool restart = mRestartAfterClose;
    const bool quitting = mQuitLease != 0;
    if (mStableSince.isValid() && mStableSince.elapsed() >= stableWindowMs)
        mRecoveries = 0;
    mDeadline.stop();
    ++mOperation;
    mChecking = false;
    stopWatching();
    mIdentity = {};
    mOwned = false;
    mStableSince.invalidate();
    mPhase.clear();
    mLaunched = false;
    mLaunchedPid = 0;
    mLaunchLease = 0;
    mCloseAttempted = false;
    mLaunchPending = false;
    mRestartAfterClose = false;
    if (quitting || (!restart && !crashed))
        mWanted = false; // Respect clean tray exit, including unknown exit code.
    const bool recover = mWanted && (restart || crashed) && (restart || mRecoveries < 3);
    const bool recoveryLimited = mWanted && !recover;
    if (recoveryLimited)
        mWanted = false; // Soft reload must not re-arm an exhausted budget.
    setState(QStringLiteral("Exited"), recoveryLimited
        ? QStringLiteral("Automatic capture host recovery limit reached; an explicit capture can retry.") : QString());
    completeQuit(true);
    if (recover) {
        if (!restart)
            ++mRecoveries;
        const auto operation = mOperation;
        QTimer::singleShot(recoveryDelayMs, this, [this, operation] {
            if (operation == mOperation && mWanted)
                ensure(mLease);
        });
    }
}

CaptureHost::CaptureHost(QObject* parent) : CaptureHost([] {
    static auto* registry = new CaptureHostRegistry(makeCaptureHostOps(), QCoreApplication::instance());
    return registry;
}(), parent) {}

CaptureHost::CaptureHost(CaptureHostRegistry* registry, QObject* parent)
    : QObject(parent), mRegistry(registry) {
    connect(registry, &CaptureHostRegistry::changed, this, &CaptureHost::changed);
    connect(registry, &CaptureHostRegistry::reloadReady, this, [this](quint64 lease, bool ok) {
        if (lease == mLease)
            emit reloadReady(ok);
    });
    connect(registry, &CaptureHostRegistry::quitReady, this, [this](quint64 lease, bool ok) {
        if (lease == mLease)
            emit quitReady(ok);
    });
}
CaptureHost::~CaptureHost() { mRegistry->release(mLease); }
QVariantMap CaptureHost::snapshot() const { return mRegistry->snapshot(); }
void CaptureHost::acquire(const QString& image, const QString& windowClass, const QStringList& options) {
    mLease = mRegistry->acquire(image, windowClass, options);
}
bool CaptureHost::command(const QStringList& args) { return mRegistry->command(mLease, args); }
bool CaptureHost::close(bool restart) {
    if (!mLease)
        mLease = mRegistry->acquireCurrent();
    return mRegistry->close(mLease, restart);
}
bool CaptureHost::quit() {
    if (!mLease)
        mLease = mRegistry->acquireCurrent();
    return mRegistry->quit(mLease);
}
bool CaptureHost::prepareReload() {
    if (!mLease)
        mLease = mRegistry->acquireCurrent();
    return mRegistry->prepareReload(mLease);
}

} // namespace caelestia::shell::windows
