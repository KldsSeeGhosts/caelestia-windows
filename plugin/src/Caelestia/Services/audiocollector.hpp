#pragma once

#include <qmutex.h>
#include <qqmlintegration.h>

#ifndef CAELESTIA_WINDOWS_AUDIO
// Windows capture uses WASAPI loopback instead of PipeWire. The ring buffer,
// refcounting and per-chunk readers stay identical on both platforms.
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#endif

#include <atomic>
#include <stop_token>
#include <thread>

#include "util/ringbuffer.hpp"
#include "service.hpp"

namespace caelestia::shell::services {

namespace ac {

constexpr quint32 k_sampleRate = 44100;
constexpr quint32 k_chunkSize = 512;

// Lockable which never makes the RT writer wait, as it only try_locks. Readers spin, they only wait on a short copy.
class SpinLock {
public:
    void lock() {
        while (m_flag.test_and_set(std::memory_order_acquire)) {
            while (m_flag.test(std::memory_order_relaxed))
                std::this_thread::yield();
        }
    }

    bool try_lock() { // NOLINT(readability-identifier-naming): Lockable requirement
        return !m_flag.test_and_set(std::memory_order_acquire);
    }

    void unlock() { m_flag.clear(std::memory_order_release); }

private:
    std::atomic_flag m_flag;
};

} // namespace ac

class AudioCollector;

#ifdef CAELESTIA_WINDOWS_AUDIO

namespace caelestia::shell::windows {
// Default-render-endpoint WASAPI loopback capture. Defined in
// Windows/Audio/wasapiloopback.cpp.
class WasapiLoopbackWorker;
} // namespace caelestia::shell::windows

#else

class PipeWireWorker {
public:
    explicit PipeWireWorker(std::stop_token token, AudioCollector* collector);

    void run();

private:
    pw_main_loop* m_loop;
    pw_stream* m_stream;
    spa_source* m_timer;
    bool m_idle;

    std::stop_token m_token;
    AudioCollector* m_collector;

    static void handleTimeout(void* data, uint64_t expirations);
    void streamStateChanged(pw_stream_state state);
    void processStream();
};

#endif

class AudioCollector : public Service {
    Q_OBJECT

public:
    AudioCollector(const AudioCollector&) = delete;
    AudioCollector& operator=(const AudioCollector&) = delete;

    static AudioCollector& instance();

    void clearBuffer();
    void loadChunk(const qint16* samples, quint32 count);
#ifdef CAELESTIA_WINDOWS_AUDIO
    // WASAPI shared-mode mixes are usually 32-bit float; skip the qint16
    // conversion the PipeWire S16 stream needs.
    void loadChunk(const float* samples, quint32 count);
#endif
    quint32 readChunk(float* out, quint32 count = 0);
    quint32 readChunk(double* out, quint32 count = 0);

private:
    explicit AudioCollector(QObject* parent = nullptr);
    ~AudioCollector() override;

    std::jthread m_thread;
    util::RingBuffer<float> m_samples;
    ac::SpinLock m_samplesLock;
    util::RingBuffer<float> m_pending; // Writer thread only, holds chunks which arrived while a reader had the lock
    std::atomic<bool> m_discardPending;
    quint32 m_sampleCount;

    template <typename T> quint32 readLatest(T* out, quint32 count);

    void reload();
    void start() override;
    void stop() override;
};

} // namespace caelestia::shell::services
