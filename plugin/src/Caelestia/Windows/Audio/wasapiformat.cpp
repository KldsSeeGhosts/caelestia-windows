#include "wasapiformat.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace caelestia::shell::windows::audio {

namespace {

constexpr GUID kSubtypeFloat = { 0x00000003, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
constexpr GUID kSubtypePcm = { 0x00000001, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

} // namespace

MixFormat mixFormatFrom(const WAVEFORMATEX* format) {
    if (!format || format->nChannels == 0) {
        return MixFormat::Unsupported;
    }

    const auto bits = format->wBitsPerSample;
    if ((bits != 16 && bits != 32) || format->nBlockAlign != format->nChannels * (bits / 8)) {
        return MixFormat::Unsupported;
    }

    bool isFloat = false;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        if (format->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
            return MixFormat::Unsupported;
        }
        const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        if (IsEqualGUID(extended->SubFormat, kSubtypeFloat)) {
            isFloat = true;
        } else if (!IsEqualGUID(extended->SubFormat, kSubtypePcm)) {
            return MixFormat::Unsupported;
        }
    } else if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        isFloat = true;
    } else if (format->wFormatTag != WAVE_FORMAT_PCM) {
        return MixFormat::Unsupported;
    }

    if (isFloat) {
        return bits == 32 ? MixFormat::Float32 : MixFormat::Unsupported;
    }
    return bits == 16 ? MixFormat::Pcm16 : MixFormat::Pcm32;
}

void downmixToMono(MixFormat format, const BYTE* data, std::size_t frames, std::size_t channels, float* mono) {
    if (!data || !mono || channels == 0) {
        return;
    }

    const auto channelScale = 1.0 / static_cast<double>(channels);
    if (format == MixFormat::Float32) {
        const auto* samples = reinterpret_cast<const float*>(data);
        for (std::size_t frame = 0; frame < frames; ++frame) {
            double sum = 0.0;
            for (std::size_t channel = 0; channel < channels; ++channel) {
                sum += samples[frame * channels + channel];
            }
            mono[frame] = static_cast<float>(sum * channelScale);
        }
    } else if (format == MixFormat::Pcm16) {
        const auto* samples = reinterpret_cast<const std::int16_t*>(data);
        for (std::size_t frame = 0; frame < frames; ++frame) {
            double sum = 0.0;
            for (std::size_t channel = 0; channel < channels; ++channel) {
                sum += static_cast<double>(samples[frame * channels + channel]) / 32768.0;
            }
            mono[frame] = static_cast<float>(sum * channelScale);
        }
    } else if (format == MixFormat::Pcm32) {
        const auto* samples = reinterpret_cast<const std::int32_t*>(data);
        for (std::size_t frame = 0; frame < frames; ++frame) {
            double sum = 0.0;
            for (std::size_t channel = 0; channel < channels; ++channel) {
                sum += static_cast<double>(samples[frame * channels + channel]) / 2147483648.0;
            }
            mono[frame] = static_cast<float>(sum * channelScale);
        }
    }
}

DWORD currentWindowsBuild() {
    static const DWORD build = []() -> DWORD {
        using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
        auto* ntdll = GetModuleHandleW(L"ntdll.dll");
        auto rtlGetVersion =
            ntdll == nullptr ? nullptr : reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));
        if (rtlGetVersion == nullptr) {
            return 0;
        }

        OSVERSIONINFOW info{};
        info.dwOSVersionInfoSize = sizeof(info);
        return rtlGetVersion(&info) == 0 ? info.dwBuildNumber : 0;
    }();

    return build;
}

} // namespace caelestia::shell::windows::audio
