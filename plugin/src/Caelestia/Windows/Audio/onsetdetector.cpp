#include "onsetdetector.hpp"

#include <algorithm>
#include <cmath>

namespace caelestia::shell::windows {

namespace {

double median(std::vector<double> values) {
    if (values.empty()) {
        return 0.0;
    }

    const auto middle = values.begin() + static_cast<std::ptrdiff_t>(values.size() / 2);
    std::nth_element(values.begin(), middle, values.end());
    double result = *middle;
    if (values.size() % 2 == 0) {
        const auto lower = std::max_element(values.begin(), middle);
        result = (*lower + result) / 2.0;
    }
    return result;
}

} // namespace

OnsetDetector::OnsetDetector(unsigned int rate)
    : m_rate(static_cast<int>(std::max(rate, 1u))) {}

void OnsetDetector::appendWindow(const double* input, int count) {
    if (count >= kFftSize) {
        std::ranges::copy(input + count - kFftSize, input + count, m_window.begin());
        m_write = 0;
        return;
    }

    const auto n = static_cast<std::size_t>(count);
    const auto firstRun = std::min(n, m_window.size() - m_write);
    std::ranges::copy(input, input + firstRun, m_window.begin() + static_cast<std::ptrdiff_t>(m_write));
    std::ranges::copy(input + firstRun, input + n, m_window.begin());
    m_write = (m_write + n) % m_window.size();
}

void OnsetDetector::updateFlux() {
    m_fft.magnitudes(m_window.data(), m_magnitudes.data());

    const double scale = 4.0 / static_cast<double>(kFftSize);
    double flux = 0.0;
    for (std::size_t bin = 1; bin < m_magnitudes.size(); ++bin) {
        const double magnitude = m_magnitudes[bin] * scale;
        flux += std::max(0.0, magnitude - m_previous[bin]);
        m_previous[bin] = magnitude;
    }

    m_fluxHistory[m_fluxWrite] = flux;
    m_fluxWrite = (m_fluxWrite + 1) % m_fluxHistory.size();
    m_fluxCount = std::min(m_fluxCount + 1, m_fluxHistory.size());
}

double OnsetDetector::process(const double* input, int count) {
    if (count <= 0) {
        return 0.0;
    }

    appendWindow(input, count);

    // Warm up the spectral history so the first frames never look like onsets.
    if (m_frames < 2) {
        ++m_frames;
        updateFlux();
        ++m_framesSinceOnset;
        return 0.0;
    }

    updateFlux();
    ++m_frames;
    ++m_framesSinceOnset;

    const double current = m_fluxHistory[(m_fluxWrite + m_fluxHistory.size() - 1) % m_fluxHistory.size()];
    double sum = 0.0;
    for (std::size_t i = 0; i < m_fluxCount; ++i) {
        sum += m_fluxHistory[i];
    }
    const double mean = m_fluxCount > 0 ? sum / static_cast<double>(m_fluxCount) : 0.0;

    double variance = 0.0;
    for (std::size_t i = 0; i < m_fluxCount; ++i) {
        variance += (m_fluxHistory[i] - mean) * (m_fluxHistory[i] - mean);
    }
    const double deviation = m_fluxCount > 0 ? std::sqrt(variance / static_cast<double>(m_fluxCount)) : 0.0;

    const bool onset = m_framesSinceOnset >= kMinOnsetFrames && current > 1e-5
        && current > mean + std::max(0.9 * deviation, mean * 0.35);
    if (!onset) {
        return 0.0;
    }

    const double frameDuration = static_cast<double>(count) / static_cast<double>(m_rate);
    const double interval = m_framesSinceOnset * frameDuration;
    m_framesSinceOnset = 0;

    // Ignore intervals outside a plausible musical tempo, but keep a gap:
    // a short gap means the player skipped a beat rather than changed tempo.
    if (interval < 0.3 || interval > 1.5) {
        return 0.0;
    }

    m_intervals.push_back(interval);
    if (m_intervals.size() > kMaxIntervals) {
        m_intervals.erase(m_intervals.begin());
    }

    double tempo = 60.0 / median(m_intervals);
    while (tempo < 70.0) {
        tempo *= 2.0;
    }
    while (tempo > 180.0) {
        tempo /= 2.0;
    }
    if (!std::isfinite(tempo) || tempo < 40.0 || tempo > 220.0) {
        return 0.0;
    }

    m_bpm = m_bpm > 0.0 ? m_bpm * 0.6 + tempo * 0.4 : tempo;
    return m_bpm;
}

} // namespace caelestia::shell::windows
