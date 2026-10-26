#pragma once

#include <memory>
#include <stop_token>

namespace caelestia::shell::services {
class AudioCollector;
}

namespace caelestia::shell::windows {

// Captures the default render endpoint with WASAPI loopback
// (AUDCLNT_STREAMFLAGS_LOOPBACK) and feeds mono 44.1 kHz frames to the shared
// AudioCollector ring buffer, which is what CavaProcessor and BeatProcessor
// read. Follows IMMNotificationClient default-output changes by recreating the
// client; failures are reported and retried, never fatal.
class WasapiLoopbackWorker {
public:
    WasapiLoopbackWorker(std::stop_token token, caelestia::shell::services::AudioCollector* collector);
    ~WasapiLoopbackWorker();

    WasapiLoopbackWorker(const WasapiLoopbackWorker&) = delete;
    WasapiLoopbackWorker& operator=(const WasapiLoopbackWorker&) = delete;

    // Blocks until the stop token is requested.
    void run();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace caelestia::shell::windows
