#pragma once

#include <cstddef>
#include <vector>

#include "cavaplan.hpp"

namespace caelestia::shell::windows {

// Windows replacement for the aubio tempo tracker used by BeatProcessor.
// Spectral-flux onsets are thresholded against a short adaptive history, and
// the tempo is the median of recent inter-onset intervals folded into a
// musical range. It reports nothing on silence, like aubio_tempo.
class OnsetDetector {
public:
    explicit OnsetDetector(unsigned int rate);

    // Feeds one analysis chunk. Returns the updated tempo in BPM when this
    // chunk contained an onset, otherwise 0.
    double process(const double* input, int count);

private:
    static constexpr int kFftSize = 1024;
    static constexpr int kHistory = 43;      // ~0.5 s of flux at 11.6 ms
    static constexpr int kMinOnsetFrames = 3; // ~170 BPM ceiling
    static constexpr std::size_t kMaxIntervals = 8;

    void appendWindow(const double* input, int count);
    void updateFlux();

    int m_rate;
    RealFft m_fft{kFftSize};
    std::vector<double> m_window = std::vector<double>(kFftSize);
    std::size_t m_write = 0;
    std::vector<double> m_magnitudes = std::vector<double>(kFftSize / 2 + 1);
    std::vector<double> m_previous = std::vector<double>(kFftSize / 2 + 1);

    std::vector<double> m_fluxHistory = std::vector<double>(kHistory);
    std::size_t m_fluxWrite = 0;
    std::size_t m_fluxCount = 0;

    int m_framesSinceOnset = 0;
    int m_frames = 0;
    std::vector<double> m_intervals;
    double m_bpm = 0.0;
};

} // namespace caelestia::shell::windows
