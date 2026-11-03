#include "wasapiloopback.hpp"

#include <qloggingcategory.h>

#include <audioclient.h>
#include <combaseapi.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stop_token>
#include <vector>

#include "audiocollector.hpp"
#include "wasapiformat.hpp"

namespace {

Q_LOGGING_CATEGORY(lcWasapi, "caelestia.audio.wasapi", QtInfoMsg)

// Render-endpoint notifications arrive on a COM thread. The worker joins the
// multi-threaded apartment, so the enumerator can call the object directly.
// The packet event is passed to IAudioClient::SetEventHandle, so the worker
// waits on one event set for every source that can change capture state.
class DeviceChangeClient final : public IMMNotificationClient {
public:
    explicit DeviceChangeClient(HANDLE deviceEvent)
        : m_deviceEvent(deviceEvent) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (!object) {
            return E_POINTER;
        }

        if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
            *object = static_cast<IMMNotificationClient*>(this);
            AddRef();
            return S_OK;
        }

        *object = nullptr;
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++m_refs; }

    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --m_refs;
        if (remaining == 0) {
            delete this;
        }
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD newState) override {
        // State-change callbacks do not carry a data flow, so any render or
        // capture endpoint transition may mean the default output moved.
        if (newState == DEVICE_STATE_ACTIVE || newState == DEVICE_STATE_DISABLED ||
            newState == DEVICE_STATE_NOTPRESENT || newState == DEVICE_STATE_UNPLUGGED) {
            SetEvent(m_deviceEvent);
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override {
        SetEvent(m_deviceEvent);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
        SetEvent(m_deviceEvent);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole, LPCWSTR) override {
        if (flow == eRender) {
            SetEvent(m_deviceEvent);
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return S_OK; }

private:
    ~DeviceChangeClient() = default;

    std::atomic<ULONG> m_refs{ 1 };
    HANDLE m_deviceEvent;
};

// Small COM holder; WRL is not part of every clang-cl MSVC-tools layout.
template <typename T> class ComPtr {
public:
    ComPtr() = default;

    ~ComPtr() { reset(); }

    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;

    T** put() {
        reset();
        return &m_ptr;
    }

    [[nodiscard]] T* get() const { return m_ptr; }

    T* operator->() const { return m_ptr; }

    explicit operator bool() const { return m_ptr != nullptr; }

    void reset() {
        if (m_ptr) {
            m_ptr->Release();
            m_ptr = nullptr;
        }
    }

private:
    T* m_ptr = nullptr;
};

} // namespace

namespace caelestia::shell::windows {

namespace ac = ::caelestia::shell::services::ac;
namespace wasapi = ::caelestia::shell::windows::audio;

struct WasapiLoopbackWorker::Impl {
    Impl(std::stop_token stopToken, caelestia::shell::services::AudioCollector* target)
        : token(std::move(stopToken))
        , collector(target) {}

    std::stop_token token;
    caelestia::shell::services::AudioCollector* collector = nullptr;

    HANDLE stopEvent = nullptr;
    HANDLE packetEvent = nullptr;
    HANDLE deviceEvent = nullptr;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    DeviceChangeClient* notifications = nullptr;
    bool notificationsRegistered = false;
    WAVEFORMATEX* mixFormat = nullptr;
    int inputRate = 0;
    wasapi::MixFormat format = wasapi::MixFormat::Unsupported;
    int channels = 0;

    std::vector<float> mono;
    std::vector<float> resampled;
    double resamplePhase = 1.0;
    float previousSample = 0.0f;
    bool haveSample = false;

    ~Impl() {
        releaseClient();
        for (auto** event : { &stopEvent, &packetEvent, &deviceEvent }) {
            if (*event) {
                CloseHandle(*event);
                *event = nullptr;
            }
        }
    }

    void releaseClient() {
        capture.reset();
        if (client) {
            client->Stop();
            client.reset();
        }
        if (mixFormat) {
            CoTaskMemFree(mixFormat);
            mixFormat = nullptr;
        }
        if (packetEvent) {
            ResetEvent(packetEvent);
        }
        if (collector) {
            // Drop the previous endpoint's window so a device switch cannot
            // replay it before the new client publishes audio.
            collector->clearBuffer();
        }
    }

    HRESULT createClient() {
        releaseClient();

        if (!enumerator) {
            return E_UNEXPECTED;
        }

        ComPtr<IMMDevice> device;
        HRESULT result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put());
        if (FAILED(result)) {
            device.reset();
            result = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, device.put());
        }
        if (FAILED(result)) {
            return result;
        }

        result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.put()));
        if (FAILED(result)) {
            return result;
        }

        result = client->GetMixFormat(&mixFormat);
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        format = wasapi::mixFormatFrom(mixFormat);
        channels = static_cast<int>(mixFormat->nChannels);
        inputRate = static_cast<int>(mixFormat->nSamplesPerSec);

        // Publish the engine period so readers can tell a starved stream from
        // an idle one without a capture timer of their own.
        REFERENCE_TIME defaultPeriod = 0;
        REFERENCE_TIME minPeriod = 0;
        if (SUCCEEDED(client->GetDevicePeriod(&defaultPeriod, &minPeriod)) && defaultPeriod > 0) {
            collector->setCapturePeriod(static_cast<quint32>((defaultPeriod + 9) / 10));
        } else {
            collector->setCapturePeriod(0);
        }

        if (format == wasapi::MixFormat::Unsupported || channels <= 0 || inputRate <= 0) {
            qCInfo(lcWasapi) << "unsupported loopback mix format"
                             << "tag" << (mixFormat ? mixFormat->wFormatTag : 0) << "bits"
                             << (mixFormat ? mixFormat->wBitsPerSample : 0);
            releaseClient();
            return AUDCLNT_E_UNSUPPORTED_FORMAT;
        }

        // Shared mode requires the engine's own mix format. Event-driven
        // buffering requires both durations to be zero, and the packet event
        // must be registered before Start.
        result = client->Initialize(AUDCLNT_SHAREMODE_SHARED, wasapi::kLoopbackFlags, 0, 0, mixFormat, nullptr);
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        result = client->SetEventHandle(packetEvent);
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        result = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(capture.put()));
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        ResetEvent(packetEvent);
        result = client->Start();
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        resamplePhase = 1.0;
        haveSample = false;
        qCInfo(lcWasapi) << "loopback capture:" << channels << "channels at" << inputRate << "Hz";
        return S_OK;
    }

    void convertFrames(const BYTE* data, UINT32 frames) {
        mono.resize(frames);
        wasapi::downmixToMono(format, data, frames, static_cast<std::size_t>(channels), mono.data());
        resample();
    }

    void pushSilence(UINT32 frames) {
        const auto outputFrames = static_cast<std::size_t>(
            std::lround(static_cast<double>(frames) * ac::k_sampleRate / std::max(inputRate, 1)));
        if (outputFrames == 0) {
            return;
        }
        resampled.assign(outputFrames, 0.0f);
        collector->loadChunk(resampled.data(), static_cast<quint32>(outputFrames));
    }

    // Linear resampling is enough for bar magnitudes and onset flux.
    void resample() {
        const double ratio = static_cast<double>(inputRate) / static_cast<double>(ac::k_sampleRate);
        resampled.clear();
        resampled.reserve(static_cast<std::size_t>(static_cast<double>(mono.size()) / ratio) + 2);

        for (const float current : mono) {
            if (!haveSample) {
                previousSample = current;
                haveSample = true;
                resamplePhase = 1.0;
                continue;
            }

            while (resamplePhase < 1.0) {
                resampled.push_back(static_cast<float>(previousSample + (current - previousSample) * resamplePhase));
                resamplePhase += ratio;
            }
            resamplePhase -= 1.0;
            previousSample = current;
        }

        if (!resampled.empty()) {
            collector->loadChunk(resampled.data(), static_cast<quint32>(resampled.size()));
        }
    }

    // Drain every packet the engine has queued. An event can cover more than
    // one packet after a delay, and GetBuffer must be paired with ReleaseBuffer.
    HRESULT pump() {
        if (!capture) {
            return E_UNEXPECTED;
        }

        for (;;) {
            UINT32 packet = 0;
            HRESULT result = capture->GetNextPacketSize(&packet);
            if (FAILED(result)) {
                return result;
            }
            if (packet == 0) {
                return S_OK;
            }

            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            result = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
            if (result == AUDCLNT_S_BUFFER_EMPTY) {
                return S_OK;
            }
            if (FAILED(result)) {
                return result;
            }

            if (frames > 0) {
                if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0) {
                    // Drop the interpolator state across a gap.
                    haveSample = false;
                }
                if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
                    pushSilence(frames);
                } else {
                    convertFrames(data, frames);
                }
            }

            result = capture->ReleaseBuffer(frames);
            if (FAILED(result)) {
                return result;
            }
        }
    }

    // Wait for the next state change that can supply a default output. Returns
    // true when the worker should stop: the stop token fired, the wait failed,
    // or endpoint notifications are unavailable so no recovery can arrive.
    bool waitForDeviceChange() {
        if (!notificationsRegistered) {
            return true;
        }

        const HANDLE handles[] = { stopEvent, deviceEvent };
        const DWORD result = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
        if (result == WAIT_OBJECT_0 + 1) {
            ResetEvent(deviceEvent);
            return false;
        }
        return true;
    }
};

WasapiLoopbackWorker::WasapiLoopbackWorker(std::stop_token token, caelestia::shell::services::AudioCollector* collector)
    : m_impl(std::make_unique<Impl>(std::move(token), collector)) {}

WasapiLoopbackWorker::~WasapiLoopbackWorker() = default;

void WasapiLoopbackWorker::run() {
    auto& self = *m_impl;

    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool comInitialized = SUCCEEDED(comResult);
    if (!comInitialized && comResult != RPC_E_CHANGED_MODE) {
        qCInfo(lcWasapi) << "COM initialization failed; audio visualisation unavailable";
        return;
    }

    self.stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    self.packetEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    self.deviceEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!self.stopEvent || !self.packetEvent || !self.deviceEvent) {
        qCInfo(lcWasapi) << "failed to create the loopback events";
        if (comInitialized) {
            CoUninitialize();
        }
        return;
    }

    {
        // Requesting stop sets the same waitable event the worker already
        // blocks on, so teardown never waits for a capture period or a retry.
        std::stop_callback stopCallback(self.token, [&self] {
            SetEvent(self.stopEvent);
        });

        if (!wasapi::eventDrivenLoopbackSupported(wasapi::currentWindowsBuild())) {
            qCInfo(lcWasapi) << "event-driven loopback requires Windows 10 1703 or newer";
            WaitForSingleObject(self.stopEvent, INFINITE);
        } else {
            HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(self.enumerator.put()));
            if (FAILED(result)) {
                qCInfo(lcWasapi) << "audio endpoint enumerator unavailable";
                WaitForSingleObject(self.stopEvent, INFINITE);
            } else {
                self.notifications = new DeviceChangeClient(self.deviceEvent);
                self.notificationsRegistered =
                    SUCCEEDED(self.enumerator->RegisterEndpointNotificationCallback(self.notifications));
                if (!self.notificationsRegistered) {
                    qCInfo(lcWasapi) << "audio endpoint notifications unavailable";
                }

                for (;;) {
                    if (!self.client) {
                        result = self.createClient();
                        if (FAILED(result)) {
                            // No endpoint, unsupported format or a denied client:
                            // wait for a device or default-device change instead of
                            // waking on a timer to retry the same state.
                            qCInfo(lcWasapi)
                                << "loopback capture unavailable" << Qt::hex << static_cast<unsigned long>(result);
                            if (self.waitForDeviceChange()) {
                                break;
                            }
                            continue;
                        }
                    }

                    const HANDLE handles[] = { self.stopEvent, self.deviceEvent, self.packetEvent };
                    const DWORD wait = WaitForMultipleObjects(3, handles, FALSE, INFINITE);
                    if (wait == WAIT_OBJECT_0) {
                        break;
                    }
                    if (wait == WAIT_OBJECT_0 + 1) {
                        ResetEvent(self.deviceEvent);
                        self.releaseClient();
                        continue;
                    }
                    if (wait == WAIT_OBJECT_0 + 2) {
                        result = self.pump();
                        if (FAILED(result)) {
                            qCInfo(lcWasapi)
                                << "loopback capture lost" << Qt::hex << static_cast<unsigned long>(result);
                            self.releaseClient();
                            if (self.waitForDeviceChange()) {
                                break;
                            }
                        }
                        continue;
                    }

                    qCInfo(lcWasapi) << "loopback wait failed" << GetLastError();
                    break;
                }
            }
        }

        if (self.notifications) {
            if (self.notificationsRegistered) {
                self.enumerator->UnregisterEndpointNotificationCallback(self.notifications);
            }
            self.notifications->Release();
            self.notifications = nullptr;
        }
        self.releaseClient();
        self.enumerator.reset();
    }

    if (comInitialized) {
        CoUninitialize();
    }
}

} // namespace caelestia::shell::windows
