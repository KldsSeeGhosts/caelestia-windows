#pragma once

#include <cstddef>
#include <utility>
#include <vector>

namespace caelestia::shell::windows {

// Minimal in-place radix-2 real FFT shared by the bar analyzer and the onset
// detector. It is deliberately Qt-free: libcava and aubio are not part of the
// Windows toolchain, so the Windows port carries its own analysis instead.
class RealFft {
public:
    explicit RealFft(int size);

    [[nodiscard]] int size() const {
        return m_size;
    }

    // Writes Hann-windowed magnitudes for bins 0..size()/2. Non-const because
    // the transform reuses its scratch buffers.
    void magnitudes(const double* input, double* magnitudes);

private:
    int m_size;
    std::vector<int> m_reverse;
    std::vector<double> m_cos;
    std::vector<double> m_sin;
    std::vector<double> m_hann;
    std::vector<double> m_re;
    std::vector<double> m_im;
};

// Windows replacement for libcava's plan/execute path used by CavaProcessor.
// The upstream processor still applies its own monstercat smoothing to these
// 0..1 values, so this class only owns the FFT, logarithmic bar bands, noise
// floor, auto-sensitivity and per-bar attack/decay.
class CavaPlan {
public:
    // Parameters mirror the subset of cava_init()/cava_execute() upstream uses.
    void init(int bars, unsigned int rate, double noiseReduction, int lowCutoff, int highCutoff);
    void execute(const double* input, int count, double* output);

private:
    static constexpr int kFftSize = 2048; // ~46 ms at 44.1 kHz; matches cava's usual window
    static constexpr int kMaxBars = 256;

    int m_bars = 0;
    int m_rate = 44100;
    double m_noiseFloorDb = -60.0;

    RealFft m_fft{kFftSize};
    std::vector<double> m_window = std::vector<double>(kFftSize);
    std::size_t m_write = 0;
    std::vector<std::pair<int, int>> m_bands;
    std::vector<double> m_magnitudes = std::vector<double>(kFftSize / 2 + 1);
    std::vector<double> m_values;
    double m_peak = 0.0;
};

} // namespace caelestia::shell::windows
