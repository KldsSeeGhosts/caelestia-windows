#pragma once

#include <qstring.h>

namespace caelestia::shell::windows {

// The three Windows "X-Mouse" values this option owns. They are read before
// the first write and written back when the option is disabled or the shell
// exits cleanly.
struct FocusFollowsMouseValues {
    bool tracking = false;
    int delayMs = 0;
    bool raise = false;
};

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

// Owns the option's live application and the saved system values. The
// controller deliberately never persists with SPIF_UPDATEINIFILE: the values
// changed here live only for this session, so a crash or forced kill cannot
// leave the user's stored preference changed. Windows restores the stored
// values at the next logon.
class FocusFollowsMouseController {
public:
    static constexpr int DEFAULT_DELAY_MS = 100;
    static constexpr int MIN_DELAY_MS = 0;
    static constexpr int MAX_DELAY_MS = 5000;

    explicit FocusFollowsMouseController(FocusFollowsMouseSystem& system);
    ~FocusFollowsMouseController();

    FocusFollowsMouseController(const FocusFollowsMouseController&) = delete;
    FocusFollowsMouseController& operator=(const FocusFollowsMouseController&) = delete;

    // Applies the option. Disabling restores the saved values; enabling
    // captures the current values first. Re-applying while enabled writes only
    // fields that differ. On failure the saved values are restored.
    bool apply(bool enabled, int delayMs, bool raise, QString* error = nullptr);

    // Restores the saved values if this controller changed anything.
    bool restore(QString* error = nullptr);

    [[nodiscard]] bool active() const { return m_active; }
    [[nodiscard]] const FocusFollowsMouseValues& saved() const { return m_saved; }
    [[nodiscard]] const FocusFollowsMouseValues& current() const { return m_current; }

    [[nodiscard]] static int clampDelay(int delayMs);

private:
    bool writeValues(const FocusFollowsMouseValues& values, QString* error);

    FocusFollowsMouseSystem& m_system;
    FocusFollowsMouseValues m_saved;
    FocusFollowsMouseValues m_current;
    bool m_active = false;
};

} // namespace caelestia::shell::windows
