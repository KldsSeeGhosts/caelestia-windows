#pragma once

#include <qlist.h>
#include <qstring.h>
#include <qtypes.h>

namespace caelestia::shell::windows {

// The three Windows "X-Mouse" values this option owns. They are read before
// the first write and written back when the option is disabled or the shell
// exits cleanly.
struct FocusFollowsMouseValues {
    bool tracking = false;
    int delayMs = 0;
    bool raise = false;
};

inline bool operator==(
    const FocusFollowsMouseValues& left, const FocusFollowsMouseValues& right) {
    return left.tracking == right.tracking && left.delayMs == right.delayMs
        && left.raise == right.raise;
}

inline bool operator!=(
    const FocusFollowsMouseValues& left, const FocusFollowsMouseValues& right) {
    return !(left == right);
}

// Injectable system boundary. The shipped implementation calls
// SystemParametersInfoW; tests use a fake so they never change the real
// desktop.
class FocusFollowsMouseSystem {
public:
    virtual ~FocusFollowsMouseSystem() = default;

    virtual bool read(FocusFollowsMouseValues& values) = 0;
    virtual bool setTracking(bool tracking) = 0;
    virtual bool setDelayMs(int delayMs) = 0;
    virtual bool setRaise(bool raise) = 0;
};

class FocusFollowsMouseController;

// Process-wide owner of the applied values. Quickshell creates the replacement
// QML generation before destroying the old one (src/core/rootwrapper.cpp), so
// controllers from two generations coexist for a moment. The replacement must
// not capture the old generation's applied values as its baseline, and the old
// destructor must not restore them while the replacement is live.
//
// The first controller to apply captures one baseline for the process (from a
// recovery file left by an unclean exit only while the system still holds that
// session's applied values, otherwise from the system). Every live controller
// then declares the values it wants; the most recent declaration wins. The
// baseline is restored only when the last controller releases or disables the
// option. Main thread only.
class FocusFollowsMouseOwner {
public:
    static FocusFollowsMouseOwner& instance();

    FocusFollowsMouseOwner() = default;
    ~FocusFollowsMouseOwner() = default;

    FocusFollowsMouseOwner(const FocusFollowsMouseOwner&) = delete;
    FocusFollowsMouseOwner& operator=(const FocusFollowsMouseOwner&) = delete;

private:
    friend class FocusFollowsMouseController;

    struct Entry {
        FocusFollowsMouseController* controller = nullptr;
        FocusFollowsMouseSystem* system = nullptr;
        FocusFollowsMouseValues desired;
        quint64 order = 0;
    };

    bool acquire(FocusFollowsMouseController& controller, FocusFollowsMouseSystem& system,
        const QString& recoveryPath, const FocusFollowsMouseValues& desired, QString* error);
    bool release(
        FocusFollowsMouseController& controller, FocusFollowsMouseSystem& system, QString* error);

    [[nodiscard]] bool registered(const FocusFollowsMouseController& controller) const;
    [[nodiscard]] const FocusFollowsMouseValues& baseline() const { return m_baseline; }
    [[nodiscard]] const FocusFollowsMouseValues& current() const { return m_current; }

    bool restoreBaseline(FocusFollowsMouseSystem& system, QString* error);
    void upsertEntry(FocusFollowsMouseController& controller, FocusFollowsMouseSystem& system,
        const FocusFollowsMouseValues& desired);
    // Rewrites the recovery file when the applied values differ from the ones
    // already recorded, so a crash after a live delay change is recovered too.
    void persistRecovery();
    void removeRecoveryFile();

    QList<Entry> m_entries;
    FocusFollowsMouseValues m_baseline;
    FocusFollowsMouseValues m_current;
    FocusFollowsMouseValues m_recoveryApplied;
    QString m_recoveryPath;
    quint64 m_nextOrder = 0;
    bool m_owned = false;
    bool m_recoveryAppliedValid = false;
};

// Controllers are owned by the QML Loader (one per generation). Each controller
// only declares this generation's intent; FocusFollowsMouseOwner holds the
// process-wide baseline and decides when the system is restored. The
// controller deliberately never persists with SPIF_UPDATEINIFILE: the values
// changed here live only for this session, so a crash or forced kill cannot
// leave the user's stored preference changed. Windows restores the stored
// values at the next logon.
class FocusFollowsMouseController {
public:
    static constexpr int DEFAULT_DELAY_MS = 100;
    static constexpr int MIN_DELAY_MS = 0;
    static constexpr int MAX_DELAY_MS = 5000;

    // Tests pass their own owner. Shipped code uses the process-wide singleton.
    explicit FocusFollowsMouseController(
        FocusFollowsMouseSystem& system, FocusFollowsMouseOwner* owner = nullptr);
    ~FocusFollowsMouseController();

    FocusFollowsMouseController(const FocusFollowsMouseController&) = delete;
    FocusFollowsMouseController& operator=(const FocusFollowsMouseController&) = delete;

    // Sets where the baseline is persisted before the first change. The QML
    // element passes the profile runtime directory. Empty disables the file.
    void setRecoveryPath(const QString& path) { m_recoveryPath = path; }

    // Applies the option. Disabling releases this controller's claim; the
    // process-wide baseline is restored when the last live controller
    // releases. Re-applying while enabled updates this controller's desired
    // values. On failure the previous values are restored.
    bool apply(bool enabled, int delayMs, bool raise, QString* error = nullptr);

    // Releases this controller's claim. If another live controller still
    // wants the option, its values stay applied.
    bool restore(QString* error = nullptr);

    [[nodiscard]] bool active() const;
    [[nodiscard]] const FocusFollowsMouseValues& saved() const;
    [[nodiscard]] const FocusFollowsMouseValues& current() const;

    [[nodiscard]] static int clampDelay(int delayMs);

private:
    FocusFollowsMouseSystem& m_system;
    FocusFollowsMouseOwner& m_owner;
    QString m_recoveryPath;
};

} // namespace caelestia::shell::windows
