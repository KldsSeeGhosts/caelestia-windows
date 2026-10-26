#include "cavaplan.hpp"

#include <algorithm>
#include <cmath>

namespace caelestia::shell::windows {

namespace {

constexpr double kPi = 3.14159265358979323846;

double clampUnit(double value) {
    return std::clamp(value, 0.0, 1.0);
}

} // namespace

RealFft::RealFft(int size)
    : m_size(size)
    , m_reverse(static_cast<std::size_t>(size))
    , m_cos(static_cast<std::size_t>(size / 2))
    , m_sin(static_cast<std::size_t>(size / 2))
    , m_hann(static_cast<std::size_t>(size))
    , m_re(static_cast<std::size_t>(size))
    , m_im(static_cast<std::size_t>(size)) {
    int bits = 0;
    while ((1 << bits) < size) {
        ++bits;
    }

    for (int i = 0; i < size; ++i) {
        int reversed = 0;
        for (int bit = 0; bit < bits; ++bit) {
            if (i & (1 << bit)) {
                reversed |= 1 << (bits - 1 - bit);
            }
        }
        m_reverse[static_cast<std::size_t>(i)] = reversed;
    }

    for (int i = 0; i < size / 2; ++i) {
        m_cos[static_cast<std::size_t>(i)] = std::cos(2.0 * kPi * i / size);
        m_sin[static_cast<std::size_t>(i)] = std::sin(2.0 * kPi * i / size);
    }

    for (int i = 0; i < size; ++i) {
        m_hann[static_cast<std::size_t>(i)] = 0.5 - 0.5 * std::cos(2.0 * kPi * i / (size - 1));
    }
}

void RealFft::magnitudes(const double* input, double* magnitudes) {
    const int n = m_size;

    // Window, then place each sample at its bit-reversed index.
    for (int i = 0; i < n; ++i) {
        const auto target = static_cast<std::size_t>(m_reverse[static_cast<std::size_t>(i)]);
        m_re[target] = input[i] * m_hann[static_cast<std::size_t>(i)];
        m_im[target] = 0.0;
    }

    for (int len = 2; len <= n; len <<= 1) {
        const int half = len >> 1;
        const int step = n / len;
        for (int base = 0; base < n; base += len) {
            for (int j = 0; j < half; ++j) {
                const auto twiddle = static_cast<std::size_t>(j * step);
                const double wr = m_cos[twiddle];
                const double wi = -m_sin[twiddle];
                const auto a = static_cast<std::size_t>(base + j);
                const auto b = static_cast<std::size_t>(base + j + half);
                const double xr = m_re[b] * wr - m_im[b] * wi;
                const double xi = m_re[b] * wi + m_im[b] * wr;
                m_re[b] = m_re[a] - xr;
                m_im[b] = m_im[a] - xi;
                m_re[a] += xr;
                m_im[a] += xi;
            }
        }
    }

    for (int k = 0; k <= n / 2; ++k) {
        const auto index = static_cast<std::size_t>(k);
        magnitudes[index] = std::sqrt(m_re[index] * m_re[index] + m_im[index] * m_im[index]);
    }
}

void CavaPlan::init(int bars, unsigned int rate, double noiseReduction, int lowCutoff, int highCutoff) {
    m_bars = std::clamp(bars, 0, kMaxBars);
    m_rate = static_cast<int>(rate);
    m_values.assign(static_cast<std::size_t>(m_bars), 0.0);
    m_bands.clear();
    m_write = 0;
    m_peak = 0.0;
    std::ranges::fill(m_window, 0.0);

    if (m_bars == 0) {
        return;
    }

    // cava maps noise_reduction to a -100..0 dB floor. A full 100 dB window
    // leaves ordinary music flat, so clamp the visible range to 40..70 dB.
    m_noiseFloorDb = std::clamp(-100.0 * noiseReduction, -70.0, -40.0);

    const double nyquist = m_rate / 2.0;
    const double low = std::clamp(static_cast<double>(lowCutoff), 1.0, nyquist);
    const double high = std::clamp(static_cast<double>(highCutoff), low, nyquist);
    const int bins = kFftSize / 2;

    m_bands.reserve(static_cast<std::size_t>(m_bars));
    for (int i = 0; i < m_bars; ++i) {
        const double f0 = low * std::pow(high / low, static_cast<double>(i) / m_bars);
        const double f1 = low * std::pow(high / low, static_cast<double>(i + 1) / m_bars);
        int first = static_cast<int>(std::floor(f0 * kFftSize / m_rate));
        int last = static_cast<int>(std::ceil(f1 * kFftSize / m_rate));
        first = std::clamp(first, 1, bins - 1);
        last = std::clamp(std::max(last, first + 1), first + 1, bins);
        m_bands.emplace_back(first, last);
    }
}

void CavaPlan::execute(const double* input, int count, double* output) {
    if (m_bars == 0 || count <= 0) {
        return;
    }

    if (count >= kFftSize) {
        input += count - kFftSize;
        count = kFftSize;
        std::ranges::copy(input, input + kFftSize, m_window.begin());
        m_write = 0;
    } else {
        const auto n = static_cast<std::size_t>(count);
        const auto firstRun = std::min(n, m_window.size() - m_write);
        std::ranges::copy(input, input + firstRun, m_window.begin() + static_cast<std::ptrdiff_t>(m_write));
        std::ranges::copy(input + firstRun, input + n, m_window.begin());
        m_write = (m_write + n) % m_window.size();
    }

    m_fft.magnitudes(m_window.data(), m_magnitudes.data());

    // Real sinusoid of amplitude A yields |X| ~ A * N / 4 with a Hann window.
    const double scale = 4.0 / static_cast<double>(kFftSize);
    const double floorDb = m_noiseFloorDb;
    const double rangeDb = -floorDb;
    double framePeak = 0.0;

    for (int i = 0; i < m_bars; ++i) {
        const auto [first, last] = m_bands[static_cast<std::size_t>(i)];
        double peak = 0.0;
        for (int bin = first; bin < last; ++bin) {
            peak = std::max(peak, m_magnitudes[static_cast<std::size_t>(bin)]);
        }

        const double amplitude = peak * scale;
        const double db = 20.0 * std::log10(std::max(amplitude, 1e-9));
        const double normalized = clampUnit((db - floorDb) / rangeDb);
        m_values[static_cast<std::size_t>(i)] = normalized;
        framePeak = std::max(framePeak, normalized);
    }

    // Auto-sensitivity mirrors cava's slowly decaying peak normalization,
    // bounded so silence does not get amplified into full-scale noise.
    m_peak = std::max({ m_peak * 0.9995, framePeak, 0.55 });
    const double gain = 1.0 / m_peak;

    for (int i = 0; i < m_bars; ++i) {
        auto& value = m_values[static_cast<std::size_t>(i)];
        const double target = clampUnit(value * gain);
        // Fast attack, slower release. CavaProcessor applies its own
        // monstercat pass on top of this.
        value += (target - value) * (target > value ? 0.6 : 0.22);
        output[i] = value;
    }
}

} // namespace caelestia::shell::windows
