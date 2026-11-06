#include "focusfollowsmouse.hpp"

#include <algorithm>

#include <qcoreapplication.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qlogging.h>
#include <qsavefile.h>
#include <qstringlist.h>
#include <qthread.h>

namespace caelestia::shell::windows {

namespace {

constexpr int RECOVERY_FILE_VERSION = 2;
constexpr qint64 MAX_RECOVERY_FILE_SIZE = 4096;

// The baseline to restore plus the values the crashed session applied. The
// baseline is trusted only while the system still holds those applied values;
// otherwise the user changed the setting in between and the live values are
// the new baseline.
struct RecoveryState {
    FocusFollowsMouseValues baseline;
    FocusFollowsMouseValues applied;
};

void assertMainThread() {
    const auto* app = QCoreApplication::instance();
    Q_ASSERT(app == nullptr || QThread::currentThread() == app->thread());
}

QByteArray serializeRecovery(const RecoveryState& state) {
    return QStringLiteral("version=%1\ntracking=%2\ndelay=%3\nraise=%4\n"
                          "appliedTracking=%5\nappliedDelay=%6\nappliedRaise=%7\n")
        .arg(RECOVERY_FILE_VERSION)
        .arg(state.baseline.tracking ? 1 : 0)
        .arg(state.baseline.delayMs)
        .arg(state.baseline.raise ? 1 : 0)
        .arg(state.applied.tracking ? 1 : 0)
        .arg(state.applied.delayMs)
        .arg(state.applied.raise ? 1 : 0)
        .toUtf8();
}

bool parseRecovery(const QByteArray& contents, RecoveryState& state) {
    int version = 0;
    bool haveVersion = false;
    bool haveTracking = false;
    bool haveDelay = false;
    bool haveRaise = false;
    bool haveAppliedTracking = false;
    bool haveAppliedDelay = false;
    bool haveAppliedRaise = false;
    RecoveryState parsed;

    const auto lines = QString::fromUtf8(contents).split(u'\n', Qt::SkipEmptyParts);
    for (const auto& line : lines) {
        const auto trimmed = line.trimmed();
        if (trimmed.isEmpty())
            continue;

        const auto key = trimmed.section(u'=', 0, 0).trimmed();
        const auto value = trimmed.section(u'=', 1).trimmed();
        if (key == QStringLiteral("version")) {
            bool ok = false;
            version = value.toInt(&ok);
            if (!ok)
                return false;
            haveVersion = true;
        } else if (key == QStringLiteral("tracking")) {
            if (value != QStringLiteral("0") && value != QStringLiteral("1"))
                return false;
            parsed.baseline.tracking = value == QStringLiteral("1");
            haveTracking = true;
        } else if (key == QStringLiteral("delay")) {
            bool ok = false;
            const auto delayMs = value.toInt(&ok);
            if (!ok || delayMs < 0)
                return false;
            parsed.baseline.delayMs = delayMs;
            haveDelay = true;
        } else if (key == QStringLiteral("raise")) {
            if (value != QStringLiteral("0") && value != QStringLiteral("1"))
                return false;
            parsed.baseline.raise = value == QStringLiteral("1");
            haveRaise = true;
        } else if (key == QStringLiteral("appliedTracking")) {
            if (value != QStringLiteral("0") && value != QStringLiteral("1"))
                return false;
            parsed.applied.tracking = value == QStringLiteral("1");
            haveAppliedTracking = true;
        } else if (key == QStringLiteral("appliedDelay")) {
            bool ok = false;
            const auto delayMs = value.toInt(&ok);
            if (!ok || delayMs < 0)
                return false;
            parsed.applied.delayMs = delayMs;
            haveAppliedDelay = true;
        } else if (key == QStringLiteral("appliedRaise")) {
            if (value != QStringLiteral("0") && value != QStringLiteral("1"))
                return false;
            parsed.applied.raise = value == QStringLiteral("1");
            haveAppliedRaise = true;
        }
    }

    // A file without applied values (including any version 1 file) can't be
    // validated, so it is discarded rather than trusted.
    if (!haveVersion || version != RECOVERY_FILE_VERSION || !haveTracking || !haveDelay
        || !haveRaise || !haveAppliedTracking || !haveAppliedDelay || !haveAppliedRaise)
        return false;

    state = parsed;
    return true;
}

bool loadRecovery(const QString& path, RecoveryState& state) {
    if (path.isEmpty())
        return false;

    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return false;
    if (file.size() > MAX_RECOVERY_FILE_SIZE)
        return false;

    return parseRecovery(file.readAll(), state);
}

bool saveRecovery(const QString& path, const RecoveryState& state) {
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;

    const auto contents = serializeRecovery(state);
    if (file.write(contents) != contents.size()) {
        file.cancelWriting();
        return false;
    }

    return file.commit();
}

// Writes only the fields that differ from the model of the live values. On
// failure the model already reflects every field that did change, so the
// caller can write a previous snapshot to roll back.
bool writeValues(FocusFollowsMouseSystem& system, const FocusFollowsMouseValues& values,
    FocusFollowsMouseValues& current, QString* error) {
    QStringList failures;

    if (values.tracking != current.tracking) {
        if (system.setTracking(values.tracking))
            current.tracking = values.tracking;
        else
            failures.append(QStringLiteral("active window tracking"));
    }

    if (values.delayMs != current.delayMs) {
        if (system.setDelayMs(values.delayMs))
            current.delayMs = values.delayMs;
        else
            failures.append(QStringLiteral("tracking delay"));
    }

    if (values.raise != current.raise) {
        if (system.setRaise(values.raise))
            current.raise = values.raise;
        else
            failures.append(QStringLiteral("raise on focus"));
    }

    if (failures.isEmpty())
        return true;

    if (error)
        *error = QStringLiteral("Couldn't change %1.").arg(failures.join(QStringLiteral(", ")));
    return false;
}

} // namespace

FocusFollowsMouseOwner& FocusFollowsMouseOwner::instance() {
    static FocusFollowsMouseOwner owner;
    return owner;
}

bool FocusFollowsMouseOwner::acquire(FocusFollowsMouseController& controller,
    FocusFollowsMouseSystem& system, const QString& recoveryPath,
    const FocusFollowsMouseValues& desiredInput, QString* error) {
    if (error)
        error->clear();
    assertMainThread();

    const FocusFollowsMouseValues desired {
        true, FocusFollowsMouseController::clampDelay(desiredInput.delayMs), desiredInput.raise};

    if (!m_owned) {
        // The baseline is the only value that must survive a crash. Reuse the
        // file left by an unclean exit only while the system still holds the
        // values that session applied; a mismatch means the user changed the
        // setting while the shell was down, so the live values are the new
        // baseline. Always read the live values so a later restore knows what
        // it has to put back.
        FocusFollowsMouseValues current;
        if (!system.read(current)) {
            if (error)
                *error = QStringLiteral("Couldn't read the Windows focus-follows-mouse settings.");
            return false;
        }

        RecoveryState recovered;
        const bool haveRecovery = !recoveryPath.isEmpty()
            && loadRecovery(recoveryPath, recovered) && recovered.applied == current;

        m_baseline = haveRecovery ? recovered.baseline : current;
        m_current = current;
        m_recoveryApplied = haveRecovery ? recovered.applied : desired;
        m_recoveryAppliedValid = false;
        m_recoveryPath = recoveryPath;
        m_owned = true;

        if (haveRecovery) {
            // The file already records this baseline and the applied values
            // matching the live system, so it needs no rewrite before the SETs.
            m_recoveryAppliedValid = true;
        } else if (!m_recoveryPath.isEmpty()) {
            // Persist before the first SET write. If this fails, change
            // nothing: a crash after an unrecorded write could leave tracking
            // on.
            if (!saveRecovery(m_recoveryPath, {m_baseline, m_recoveryApplied})) {
                m_owned = false;
                m_recoveryPath.clear();
                if (error)
                    *error = QStringLiteral(
                        "Couldn't save the Windows focus-follows-mouse recovery state.");
                return false;
            }
            m_recoveryAppliedValid = true;
        }
    }

    const auto previous = m_current;
    QString writeError;
    if (!writeValues(system, desired, m_current, &writeError)) {
        // A partially applied setting is worse than none. Other live
        // controllers keep their values; a failed first controller gives
        // ownership back.
        QString rollbackError;
        const bool rolledBack = writeValues(system, previous, m_current, &rollbackError);
        if (m_entries.isEmpty() && rolledBack && m_current == m_baseline) {
            m_owned = false;
            removeRecoveryFile();
            m_recoveryPath.clear();
        } else if (m_entries.isEmpty()) {
            // Keep a retry path for the destructor; active() reports the error
            // until then.
            upsertEntry(controller, system, desired);
            persistRecovery();
        } else {
            persistRecovery();
        }
        if (error)
            *error = writeError;
        return false;
    }

    upsertEntry(controller, system, desired);
    persistRecovery();
    return true;
}

bool FocusFollowsMouseOwner::release(
    FocusFollowsMouseController& controller, FocusFollowsMouseSystem& system, QString* error) {
    if (error)
        error->clear();
    assertMainThread();

    qsizetype index = -1;
    for (qsizetype i = 0; i < m_entries.size(); ++i) {
        if (m_entries[i].controller == &controller) {
            index = i;
            break;
        }
    }

    if (index < 0) {
        // This controller never claimed the option. If ownership was left
        // behind with no live controller (a failed last restore), retry it.
        if (m_entries.isEmpty() && m_owned)
            return restoreBaseline(system, error);
        return true;
    }

    m_entries.removeAt(index);

    if (!m_entries.isEmpty()) {
        // The most recent declaration wins. Re-apply it in case the released
        // controller had overwritten it.
        const Entry* latest = &m_entries.first();
        for (const auto& entry : m_entries) {
            if (entry.order > latest->order)
                latest = &entry;
        }

        QString writeError;
        if (!writeValues(*latest->system, latest->desired, m_current, &writeError)) {
            persistRecovery();
            if (error)
                *error = writeError;
            return false;
        }
        persistRecovery();
        return true;
    }

    return restoreBaseline(system, error);
}

bool FocusFollowsMouseOwner::registered(const FocusFollowsMouseController& controller) const {
    for (const auto& entry : m_entries) {
        if (entry.controller == &controller)
            return true;
    }
    return false;
}

bool FocusFollowsMouseOwner::restoreBaseline(
    FocusFollowsMouseSystem& system, QString* error) {
    if (!m_owned)
        return true;

    QString writeError;
    if (!writeValues(system, m_baseline, m_current, &writeError)) {
        // Keep the file in step with whatever restore managed to apply so a
        // later crash recovers the remaining baseline values.
        persistRecovery();
        if (error)
            *error = writeError;
        return false;
    }

    m_owned = false;
    removeRecoveryFile();
    m_recoveryPath.clear();
    return true;
}

void FocusFollowsMouseOwner::persistRecovery() {
    if (!m_owned || m_recoveryPath.isEmpty() || !m_recoveryAppliedValid
        || m_recoveryApplied == m_current)
        return;

    if (!saveRecovery(m_recoveryPath, {m_baseline, m_current})) {
        qWarning("Couldn't update the focus-follows-mouse recovery file.");
        return;
    }
    m_recoveryApplied = m_current;
}

void FocusFollowsMouseOwner::upsertEntry(FocusFollowsMouseController& controller,
    FocusFollowsMouseSystem& system, const FocusFollowsMouseValues& desired) {
    for (auto& entry : m_entries) {
        if (entry.controller == &controller) {
            entry.system = &system;
            entry.desired = desired;
            entry.order = ++m_nextOrder;
            return;
        }
    }

    m_entries.append({&controller, &system, desired, ++m_nextOrder});
}

void FocusFollowsMouseOwner::removeRecoveryFile() {
    m_recoveryAppliedValid = false;
    if (m_recoveryPath.isEmpty())
        return;

    if (!QFile::remove(m_recoveryPath) && QFileInfo::exists(m_recoveryPath))
        qWarning("Couldn't remove the focus-follows-mouse recovery file.");
}

FocusFollowsMouseController::FocusFollowsMouseController(
    FocusFollowsMouseSystem& system, FocusFollowsMouseOwner* owner)
    : m_system(system)
    , m_owner(owner ? *owner : FocusFollowsMouseOwner::instance()) {}

FocusFollowsMouseController::~FocusFollowsMouseController() {
    restore();
}

int FocusFollowsMouseController::clampDelay(int delayMs) {
    return std::clamp(delayMs, MIN_DELAY_MS, MAX_DELAY_MS);
}

bool FocusFollowsMouseController::apply(
    bool enabled, int delayMs, bool raise, QString* error) {
    if (!enabled)
        return restore(error);

    return m_owner.acquire(*this, m_system, m_recoveryPath,
        FocusFollowsMouseValues {true, clampDelay(delayMs), raise}, error);
}

bool FocusFollowsMouseController::restore(QString* error) {
    return m_owner.release(*this, m_system, error);
}

bool FocusFollowsMouseController::active() const {
    return m_owner.registered(*this);
}

const FocusFollowsMouseValues& FocusFollowsMouseController::saved() const {
    return m_owner.baseline();
}

const FocusFollowsMouseValues& FocusFollowsMouseController::current() const {
    return m_owner.current();
}

} // namespace caelestia::shell::windows
