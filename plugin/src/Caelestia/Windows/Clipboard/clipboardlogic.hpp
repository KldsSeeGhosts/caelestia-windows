#pragma once

#include <algorithm>
#include <cstdint>

#include <qstring.h>

namespace caelestia::shell::windows {

// Windows.ApplicationModel.DataTransfer.SetHistoryItemAsContentStatus values.
// They are part of the WinRT ABI (Success = 0, AccessDenied = 1,
// ItemDeleted = 2), but the worker only needs the decision, so it is kept out
// of WinRT headers and can be exercised by the light logic test.
enum class ClipboardSetContentStatus : int {
    Success = 0,
    AccessDenied = 1,
    ItemDeleted = 2,
};

struct ClipboardContentResult {
    bool ok = false;
    QString message;
};

// SetHistoryItemAsContent without a Success status must never be reported or
// followed by a synthetic paste: the clipboard still holds the previous entry.
[[nodiscard]] inline ClipboardContentResult clipboardSetContentResult(int status) {
    switch (static_cast<ClipboardSetContentStatus>(status)) {
    case ClipboardSetContentStatus::Success:
        return {true, {}};
    case ClipboardSetContentStatus::AccessDenied:
        return {false, QStringLiteral("Windows denied access to the clipboard history item.")};
    case ClipboardSetContentStatus::ItemDeleted:
        return {false, QStringLiteral("The clipboard history item was deleted before it could be used.")};
    }
    return {false,
        QStringLiteral("Windows returned an unknown clipboard item status (%1).").arg(status)};
}

// Event-driven refresh scheduling for the clipboard worker.
//
// Clipboard.HistoryChanged/HistoryEnabledChanged only cause a coalesced read
// while the picker is open. Every activation, deactivation and explicit read
// starts a new generation, so a read scheduled for a closed picker (or a
// completion that arrives after the picker closed) is ignored instead of
// reading or publishing history while nothing is on screen.
class ClipboardRefreshGate {
public:
    enum class EventDecision {
        Ignore,
        Schedule,
    };

    enum class TimeoutDecision {
        Ignore,
        Refresh,
    };

    // A picker session change invalidates any pending event and read.
    void setActive(bool active) {
        m_active = active;
        m_pending = false;
        ++m_generation;
    }

    [[nodiscard]] bool active() const { return m_active; }
    [[nodiscard]] bool pending() const { return m_pending; }
    [[nodiscard]] quint64 generation() const { return m_generation; }

    // Called when a WinRT change event arrives.
    [[nodiscard]] EventDecision onEvent() {
        if (!m_active)
            return EventDecision::Ignore;
        m_pending = true;
        return EventDecision::Schedule;
    }

    // Called when the coalescing timer fires.
    [[nodiscard]] TimeoutDecision onTimeout() {
        if (!m_active || !m_pending)
            return TimeoutDecision::Ignore;
        m_pending = false;
        return TimeoutDecision::Refresh;
    }

    // Called whenever a history read starts; invalidates older completions.
    [[nodiscard]] quint64 nextRead() { return ++m_generation; }

    // A completion is only published when no newer read or session change has
    // happened since it started.
    [[nodiscard]] bool accepts(quint64 generation) const {
        return m_active && generation == m_generation;
    }

private:
    bool m_active = false;
    bool m_pending = false;
    quint64 m_generation = 0;
};

} // namespace caelestia::shell::windows
