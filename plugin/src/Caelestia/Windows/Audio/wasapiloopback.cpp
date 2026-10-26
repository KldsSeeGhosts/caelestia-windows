#include "wasapiloopback.hpp"

#include <qloggingcategory.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "audiocollector.hpp"

#include <windows.h>
#include <audioclient.h>
#include <combaseapi.h>
#include <mmdeviceapi.h>
#include <mmreg.h>

namespace {

Q_LOGGING_CATEGORY(lcWasapi, "caelestia.audio.wasapi", QtInfoMsg)

// Render-endpoint notifications arrive on a COM thread. The worker joins the
// multi-threaded apartment, so the enumerator can call this object directly.
class DeviceChangeClient final : public IMMNotificationClient {
public:
    explicit DeviceChangeClient(HANDLE wakeEvent)
        : m_wakeEvent(wakeEvent) {}

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

    ULONG STDMETHODCALLTYPE AddRef() override {
        return ++m_refs;
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --m_refs;
        if (remaining == 0) {
            delete this;
        }
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override {
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        // Follow the default render endpoint in every role the shell may use.
        if (flow == eRender && (role == eConsole || role == eMultimedia)) {
            SetEvent(m_wakeEvent);
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override {
        return S_OK;
    }

private:
    ~DeviceChangeClient() = default;

    std::atomic<ULONG> m_refs{ 1 };
    HANDLE m_wakeEvent;
};

// Small COM holder; WRL is not part of every clang-cl MSVC-tools layout.
template <typename T> class ComPtr {
public:
    ComPtr() = default;
    ~ComPtr() {
        reset();
    }

    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;

    T** put() {
        reset();
        return &m_ptr;
    }

    [[nodiscard]] T* get() const {
        return m_ptr;
    }

    T* operator->() const {
        return m_ptr;
    }

    explicit operator bool() const {
        return m_ptr != nullptr;
    }

    void reset() {
        if (m_ptr) {
            m_ptr->Release();
            m_ptr = nullptr;
        }
    }

private:
    T* m_ptr = nullptr;
};

constexpr GUID kSubtypeFloat = { 0x00000003, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
constexpr GUID kSubtypePcm = { 0x00000001, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

} // namespace

namespace caelestia::shell::windows {

namespace ac = ::caelestia::shell::services::ac;

struct WasapiLoopbackWorker::Impl {
    enum class Format { Float32, Pcm16, Pcm32, Unsupported };

    Impl(std::stop_token stopToken, caelestia::shell::services::AudioCollector* target)
        : token(std::move(stopToken))
        , collector(target) {}

    std::stop_token token;
    caelestia::shell::services::AudioCollector* collector = nullptr;

    HANDLE wakeEvent = nullptr;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    DeviceChangeClient* notifications = nullptr;
    WAVEFORMATEX* mixFormat = nullptr;
    int inputRate = 0;
    Format format = Format::Unsupported;
    int channels = 0;

    std::vector<float> mono;
    std::vector<float> resampled;
    double resamplePhase = 1.0;
    float previousSample = 0.0f;
    bool haveSample = false;

    UINT32 idlePolls = 0;
    bool clearedForIdle = false;

    ~Impl() {
        releaseClient();
        if (wakeEvent) {
            CloseHandle(wakeEvent);
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
    }

    [[nodiscard]] Format formatFrom(const WAVEFORMATEX* waveFormat) const {
        if (!waveFormat) {
            return Format::Unsupported;
        }

        if (waveFormat->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
            const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(waveFormat);
            if (IsEqualGUID(extended->SubFormat, kSubtypeFloat)) {
                return Format::Float32;
            }
            if (IsEqualGUID(extended->SubFormat, kSubtypePcm)) {
                return waveFormat->wBitsPerSample == 16 ? Format::Pcm16 : Format::Pcm32;
            }
            return Format::Unsupported;
        }

        if (waveFormat->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
            return Format::Float32;
        }
        if (waveFormat->wFormatTag == WAVE_FORMAT_PCM) {
            return waveFormat->wBitsPerSample == 16 ? Format::Pcm16 : Format::Pcm32;
        }
        return Format::Unsupported;
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

        format = formatFrom(mixFormat);
        channels = static_cast<int>(mixFormat->nChannels);
        inputRate = static_cast<int>(mixFormat->nSamplesPerSec);
        if (format == Format::Unsupported || channels <= 0 || inputRate <= 0) {
            qCInfo(lcWasapi) << "unsupported loopback mix format"
                             << "tag" << (mixFormat ? mixFormat->wFormatTag : 0) << "bits"
                             << (mixFormat ? mixFormat->wBitsPerSample : 0);
            releaseClient();
            return AUDCLNT_E_UNSUPPORTED_FORMAT;
        }

        // Shared mode requires the engine's own mix format. A zero duration
        // lets the engine pick the period; loopback is polled below.
        result = client->Initialize(
            AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 0, 0, mixFormat, nullptr);
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        result =
            client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(capture.put()));
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        result = client->Start();
        if (FAILED(result)) {
            releaseClient();
            return result;
        }

        resamplePhase = 1.0;
        haveSample = false;
        idlePolls = 0;
        clearedForIdle = false;
        return S_OK;
    }

    void convertFrames(const BYTE* data, UINT32 frames) {
        mono.resize(frames);
        const auto frameCount = static_cast<std::size_t>(frames);
        const auto channelCount = static_cast<std::size_t>(channels);

        if (format == Format::Float32) {
            const auto* samples = reinterpret_cast<const float*>(data);
            for (std::size_t frame = 0; frame < frameCount; ++frame) {
                double sum = 0.0;
                for (std::size_t channel = 0; channel < channelCount; ++channel) {
                    sum += samples[frame * channelCount + channel];
                }
                mono[frame] = static_cast<float>(sum / static_cast<double>(channelCount));
            }
        } else if (format == Format::Pcm16) {
            const auto* samples = reinterpret_cast<const qint16*>(data);
            for (std::size_t frame = 0; frame < frameCount; ++frame) {
                double sum = 0.0;
                for (std::size_t channel = 0; channel < channelCount; ++channel) {
                    sum += static_cast<double>(samples[frame * channelCount + channel]) / 32768.0;
                }
                mono[frame] = static_cast<float>(sum / static_cast<double>(channelCount));
            }
        } else {
            const auto* samples = reinterpret_cast<const qint32*>(data);
            for (std::size_t frame = 0; frame < frameCount; ++frame) {
                double sum = 0.0;
                for (std::size_t channel = 0; channel < channelCount; ++channel) {
                    sum += static_cast<double>(samples[frame * channelCount + channel]) / 2147483648.0;
                }
                mono[frame] = static_cast<float>(sum / static_cast<double>(channelCount));
            }
        }

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
                resampled.push_back(
                    static_cast<float>(previousSample + (current - previousSample) * resamplePhase));
                resamplePhase += ratio;
            }
            resamplePhase -= 1.0;
            previousSample = current;
        }

        if (!resampled.empty()) {
            collector->loadChunk(resampled.data(), static_cast<quint32>(resampled.size()));
        }
    }

    void pump() {
        UINT32 padding = 0;
        HRESULT result = client->GetCurrentPadding(&padding);
        if (FAILED(result)) {
            releaseClient();
            return;
        }

        if (padding == 0) {
            // The render engine produces nothing while the endpoint is idle;
            // decay the bars instead of holding the last window forever.
            if (++idlePolls >= 25 && !clearedForIdle) {
                collector->clearBuffer();
                clearedForIdle = true;
            }
            return;
        }

        idlePolls = 0;
        clearedForIdle = false;

        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        result = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(result)) {
            releaseClient();
            return;
        }

        if (frames > 0) {
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
                pushSilence(frames);
            } else if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0) {
                // Drop the interpolator state across a gap.
                haveSample = false;
                convertFrames(data, frames);
            } else {
                convertFrames(data, frames);
            }
        }

        capture->ReleaseBuffer(frames);
    }
};

WasapiLoopbackWorker::WasapiLoopbackWorker(
    std::stop_token token, caelestia::shell::services::AudioCollector* collector)
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

    self.wakeEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!self.wakeEvent) {
        qCInfo(lcWasapi) << "failed to create the endpoint-change event";
        if (comInitialized) {
            CoUninitialize();
        }
        return;
    }

    HRESULT result = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void**>(self.enumerator.put()));
    if (FAILED(result)) {
        qCInfo(lcWasapi) << "audio endpoint enumerator unavailable";
        if (comInitialized) {
            CoUninitialize();
        }
        return;
    }

    self.notifications = new DeviceChangeClient(self.wakeEvent);
    self.enumerator->RegisterEndpointNotificationCallback(self.notifications);

    while (!self.token.stop_requested()) {
        if (!self.client) {
            result = self.createClient();
            if (FAILED(result)) {
                // No endpoint, unsupported format or a denied client: idle
                // quietly and retry so a device plugged in later starts bars.
                for (int i = 0; i < 50 && !self.token.stop_requested(); ++i) {
                    if (WaitForSingleObject(self.wakeEvent, 20) == WAIT_OBJECT_0) {
                        ResetEvent(self.wakeEvent);
                        break;
                    }
                }
                continue;
            }
        }

        if (WaitForSingleObject(self.wakeEvent, 12) == WAIT_OBJECT_0) {
            ResetEvent(self.wakeEvent);
            self.releaseClient();
            continue;
        }

        if (self.token.stop_requested()) {
            break;
        }

        self.pump();
    }

    self.enumerator->UnregisterEndpointNotificationCallback(self.notifications);
    self.notifications->Release();
    self.notifications = nullptr;
    self.releaseClient();
    self.enumerator.reset();

    if (comInitialized) {
        CoUninitialize();
    }
}

} // namespace caelestia::shell::windows
