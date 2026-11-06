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
        const auto directory = QDir::toNativeSeparators(QFileInfo(image).absolutePath());
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
        process->setWorkingDirectory(QFileInfo(image).absolutePath());
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

bool CaptureHostRegistry::writer(quint64 lease) const { return lease && lease == mLease; }

void CaptureHostRegistry::setState(const QString& state, const QString& error) {
    mState = state;
    mError = error;
    emit changed();
}

QVariantMap CaptureHostRegistry::snapshot() const {
    return {{QStringLiteral("state"), mState}, {QStringLiteral("error"), mError},
        {QStringLiteral("owned"), bool(mIdentity.handle)},
        {QStringLiteral("launched"), mLaunched && mLaunchLease == mLease && mState == QStringLiteral("Owned")},
        {QStringLiteral("pid"), mIdentity.pid}, {QStringLiteral("hostId"), mIdentity.hostId},
        {QStringLiteral("phase"), mPhase}, {QStringLiteral("checking"), mChecking},
        {QStringLiteral("closeAttempted"), mCloseAttempted}};
}

quint64 CaptureHostRegistry::acquire(const QString& image, const QString& windowClass, const QStringList& options) {
    mLease = ++mSerial;
    completeReload(mReloadLease, false);
    // A different payload is never silently adopted by soft reload. Installation
    // replacement uses full quit/Stop-CaelestiaHosts, not this handoff.
    if (mIdentity.handle && (!sameImage(image, mImage) || windowClass != mClass)) {
        mImage = image;
        mClass = windowClass;
        mOptions = options;
        mWanted = false; // Never recover the retired payload after its exit.
        setState(QStringLiteral("Foreign"), QStringLiteral("Capture host belongs to another payload; full stop required."));
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
    mIdentity = identity;
    mLaunched = mLaunchedPid != 0 && mLaunchedPid == identity.pid;
    delete mWatch;
    mWatch = mOps->watch(mIdentity, this, [this, pid = identity.pid, created = identity.created] {
        if (mIdentity.pid == pid && mIdentity.created == created)
            exited();
    });
}

void CaptureHostRegistry::ensure(quint64 lease) {
    if (!writer(lease) || mChecking || !mWanted || mCloseAttempted || mLaunchPending
        || mState == QStringLiteral("Starting") || mState == QStringLiteral("Foreign"))
        return;
    if (mIdentity.handle)
        return; // Includes uncertain/closing identities, never re-adopt.
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
            if (acceptStatus(status))
                setState(QStringLiteral("Owned"));
            else
                setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host status could not be verified."));
        } else {
            setState(probe.kind == CaptureProbe::Foreign ? QStringLiteral("Foreign") : QStringLiteral("CloseFailed"),
                QStringLiteral("Capture host identity is foreign or inaccessible; no process was changed."));
        }
    });
}

bool CaptureHostRegistry::launch(const QStringList& args) {
    if (mIdentity.handle || mCloseAttempted || mAttempts >= 3) {
        setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host recovery limit reached."));
        return false;
    }
    ++mAttempts;
    mLaunchLease = mLease;
    mLaunchedPid = 0;
    CaptureIdentity child;
    if (!mOps->launch(mImage, args, child)) {
        setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host launch failed."));
        return false;
    }
    mLaunchedPid = child.pid;
    mLaunchPending = true;
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
        if (mState != QStringLiteral("Starting"))
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
            if (acceptStatus(status)) {
                mLaunchPending = false;
                mDeadline.stop();
                setState(QStringLiteral("Owned"));
                return;
            }
        }
        // Retain startup uncertainty and its deadline, never claim launch from
        // the lifetime of a forwarding command client.
        emit changed();
        QTimer::singleShot(100, this, [this] {
            if (mState == QStringLiteral("Starting") && !mChecking)
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
        const bool ok = acceptStatus(status);
        if (!ok)
            setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host health/identity could not be verified."));
        else
            emit changed();
        complete(ok);
    });
}

bool CaptureHostRegistry::command(quint64 lease, const QStringList& args) {
    if (writer(lease) && !mChecking && !mIdentity.handle && !mCloseAttempted
        && (mState == QStringLiteral("Absent") || mState == QStringLiteral("Exited"))) {
        mWanted = true;
        mAttempts = 0; // An explicit user command can re-arm bounded recovery.
        return launch(args);
    }
    if (!writer(lease) || mChecking || mCloseAttempted || mState != QStringLiteral("Owned") || !verified())
        return false;
    CaptureIdentity forwardingClient;
    // Forwarding to an existing host never grants launchedHost freshness.
    return mOps->launch(mImage, args, forwardingClient);
}

bool CaptureHostRegistry::close(quint64 lease, bool restart) {
    if (!writer(lease) || mChecking || mCloseAttempted)
        return false;
    if (mState == QStringLiteral("Absent") || mState == QStringLiteral("Exited")) {
        mWanted = restart;
        if (restart) {
            mAttempts = 0;
            ensure(lease);
        }
        return true;
    }
    if (mState != QStringLiteral("Owned") || !verified()) {
        mError = QStringLiteral("Capture host close refused: identity is not verified.");
        emit changed();
        return false;
    }
    check([this, lease, restart](bool ok) {
        if (!writer(lease)) {
            mError = QStringLiteral("Capture host close superseded by a newer generation.");
            emit changed();
            return;
        }
        if (!ok || mPhase != QStringLiteral("idle") || mOps->hasCaptureWindow(mIdentity)) {
            if (ok)
                mError = QStringLiteral("Capture host close refused: capture or recording is active.");
            emit changed();
            return;
        }
        mWanted = restart;
        if (restart)
            mAttempts = 0;
        mCloseAttempted = true;
        setState(QStringLiteral("Closing"));
        if (!verified() || !mOps->postClose(mIdentity)) {
            setState(QStringLiteral("CloseFailed"), QStringLiteral("Capture host close could not be posted; ownership retained."));
            return;
        }
        mDeadline.start(closeTimeoutMs);
    });
    return true; // Accepted for asynchronous checking, not completion.
}

bool CaptureHostRegistry::prepareReload(quint64 lease) {
    if (!writer(lease))
        return false;
    if (mChecking || mCloseAttempted) {
        mError = QStringLiteral("Capture handoff refused: host operation is pending.");
        emit changed();
        return false;
    }
    if (mState == QStringLiteral("Absent") || mState == QStringLiteral("Exited")) {
        mReloadLease = lease;
        QTimer::singleShot(0, this, [this, lease] { completeReload(lease, writer(lease)); });
        return true;
    }
    if (mState != QStringLiteral("Owned") || !verified()) {
        mError = QStringLiteral("Capture handoff refused: host is not healthy and verified.");
        emit changed();
        return false;
    }
    mReloadLease = lease;
    check([this, lease](bool ok) {
        // Recording is deliberately allowed. A reload does not close the host.
        completeReload(lease, ok && writer(lease));
    });
    return true;
}

void CaptureHostRegistry::completeReload(quint64 lease, bool ok) {
    if (!lease || lease != mReloadLease)
        return;
    mReloadLease = 0;
    emit reloadReady(lease, ok);
}

void CaptureHostRegistry::deadline() {
    // Cancel a pending status response logically, not by deleting its running
    // client. Its eventual response must not adopt a timed-out startup.
    ++mOperation;
    mChecking = false;
    setState(QStringLiteral("CloseFailed"),
        QStringLiteral("Capture host deadline missed; exit is unconfirmed and ownership retained."));
    completeReload(mReloadLease, false);
}

void CaptureHostRegistry::exited() {
    mDeadline.stop();
    ++mOperation;
    mChecking = false;
    if (mWatch) {
        mWatch->deleteLater();
        mWatch = nullptr;
    }
    mIdentity = {};
    mPhase.clear();
    mLaunched = false;
    mLaunchedPid = 0;
    mLaunchLease = 0;
    mCloseAttempted = false;
    mLaunchPending = false;
    setState(QStringLiteral("Exited"), mWanted && mAttempts >= 3
        ? QStringLiteral("Automatic capture host recovery limit reached; an explicit capture can retry.") : QString());
    completeReload(mReloadLease, false);
    if (mLease && mWanted && mAttempts < 3) {
        QTimer::singleShot(recoveryDelayMs, this, [this] { ensure(mLease); });
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
}
CaptureHost::~CaptureHost() { mRegistry->release(mLease); }
QVariantMap CaptureHost::snapshot() const { return mRegistry->snapshot(); }
void CaptureHost::acquire(const QString& image, const QString& windowClass, const QStringList& options) {
    mLease = mRegistry->acquire(image, windowClass, options);
}
bool CaptureHost::command(const QStringList& args) { return mRegistry->command(mLease, args); }
bool CaptureHost::close(bool restart) { return mRegistry->close(mLease, restart); }
bool CaptureHost::prepareReload() { return mRegistry->prepareReload(mLease); }

} // namespace caelestia::shell::windows
