#pragma once

#include <audioclient.h>
#include <mmreg.h>
#include <windows.h>

#include <cstddef>
#include <cstdint>

namespace caelestia::shell::windows::audio {

// Shared-mode loopback formats the worker can downmix without overreading a
// packet. Anything else (8-bit, packed 24-bit, odd block alignment) is rejected.
enum class MixFormat : std::uint8_t {
    Float32,
    Pcm16,
    Pcm32,
    Unsupported
};

// Microsoft documents that a loopback stream opened with
// AUDCLNT_STREAMFLAGS_EVENTCALLBACK raises no buffer-ready events before
// Windows 10 1703 (build 15063); Initialize still succeeds, so the failure is
// invisible to the HRESULT. The shell targets Windows 11, so require the
// documented support instead of falling back to a polling timer.
// https://learn.microsoft.com/windows/win32/coreaudio/loopback-recording
constexpr DWORD kEventDrivenLoopbackBuild = 15063;

constexpr DWORD kLoopbackFlags = static_cast<DWORD>(AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK);

[[nodiscard]] MixFormat mixFormatFrom(const WAVEFORMATEX* format);

// Averaging downmix of one interleaved packet to mono. `data` must match
// `format` and `channels * bytesPerSample` block alignment.
void downmixToMono(MixFormat format, const BYTE* data, std::size_t frames, std::size_t channels, float* mono);

// The build number of the running OS, or 0 when ntdll cannot report it.
[[nodiscard]] DWORD currentWindowsBuild();

[[nodiscard]] constexpr bool eventDrivenLoopbackSupported(DWORD build) {
    return build == 0 || build >= kEventDrivenLoopbackBuild;
}

} // namespace caelestia::shell::windows::audio
