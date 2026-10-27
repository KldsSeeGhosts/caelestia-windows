#pragma once

#include <atomic>

#include <qglobal.h>

namespace caelestia::shell::windows {

// The picker session and the stop request are shared between the GUI facade
// and the worker thread. The facade publishes close/deactivation immediately
// through these atomics instead of a queued call, so a blocking per-item read
// on the worker cannot publish history after the picker has closed.
//
// Memory ordering: a session change increments the generation before (activate)
// or after (deactivate) the active flag, and readers load both with acquire.
// Any read that started before the change therefore fails accepts(), whether
// it observes the flag, the newer generation, or both.
class ClipboardSessionState {
public:
    void activate() {
        m_generation.fetch_add(1, std::memory_order_acq_rel);
        m_active.store(true, std::memory_order_release);
    }

    void deactivate() {
        m_active.store(false, std::memory_order_release);
        m_generation.fetch_add(1, std::memory_order_acq_rel);
    }

    // Starts a new read. The returned token is accepted only while the session
    // is still active and no newer read, close or reopen has happened.
    [[nodiscard]] quint64 nextRead() {
        return m_generation.fetch_add(1, std::memory_order_acq_rel) + 1;
    }

    [[nodiscard]] bool accepts(quint64 read) const {
        return m_active.load(std::memory_order_acquire)
            && m_generation.load(std::memory_order_acquire) == read;
    }

    // The GUI-side gate for a queued snapshot. It must still belong to the
    // current open session: a snapshot emitted before a close, or by a previous
    // session before a reopen, is dropped even if it was queued successfully.
    [[nodiscard]] bool acceptsSnapshot(quint64 generation) const {
        return !stopping() && accepts(generation);
    }

    [[nodiscard]] bool active() const { return m_active.load(std::memory_order_acquire); }

    void requestStop() { m_stopping.store(true, std::memory_order_release); }
    [[nodiscard]] bool stopping() const { return m_stopping.load(std::memory_order_acquire); }

private:
    std::atomic<bool> m_active {false};
    std::atomic<bool> m_stopping {false};
    std::atomic<quint64> m_generation {0};
};

} // namespace caelestia::shell::windows
