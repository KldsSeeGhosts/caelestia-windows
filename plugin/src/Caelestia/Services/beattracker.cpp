#include "beattracker.hpp"

#include <algorithm>
#include <span>
#include <vector>

#include "audiocollector.hpp"
#include "audioprovider.hpp"

namespace caelestia::shell::services {

#ifdef CAELESTIA_WINDOWS_AUDIO

BeatProcessor::BeatProcessor(QObject* parent)
    : AudioProcessor(parent)
    , m_detector(ac::k_sampleRate)
    , m_in(new float[ac::k_chunkSize]) {};

BeatProcessor::~BeatProcessor() {
    delete[] m_in;
}

void BeatProcessor::process() {
    if (!m_in) {
        return;
    }

    const auto count = AudioCollector::instance().readChunk(m_in);

    // The detector needs doubles; the collector window is 512 mono samples.
    thread_local std::vector<double> samples;
    samples.resize(count);
    std::ranges::transform(std::span(m_in, count), samples.begin(), [](float value) {
        return static_cast<double>(value);
    });

    const double bpm = m_detector.process(samples.data(), static_cast<int>(count));
    if (bpm > 0.0) {
        emit beat(static_cast<smpl_t>(bpm));
    }
}

#else

BeatProcessor::BeatProcessor(QObject* parent)
    : AudioProcessor(parent)
    , m_tempo(new_aubio_tempo("default", 1024, ac::k_chunkSize, ac::k_sampleRate))
    , m_in(new_fvec(ac::k_chunkSize))
    , m_out(new_fvec(2)) {};

BeatProcessor::~BeatProcessor() {
    if (m_tempo) {
        del_aubio_tempo(m_tempo);
    }
    if (m_in) {
        del_fvec(m_in);
    }
    if (m_out) {
        del_fvec(m_out);
    }
}

void BeatProcessor::process() {
    if (!m_tempo || !m_in) {
        return;
    }

    AudioCollector::instance().readChunk(m_in->data);

    aubio_tempo_do(m_tempo, m_in, m_out);
    if (!qFuzzyIsNull(m_out->data[0])) {
        emit beat(aubio_tempo_get_bpm(m_tempo));
    }
}

#endif

BeatTracker::BeatTracker(QObject* parent)
    : AudioProvider(parent)
    , m_bpm(120) {
    m_processor = new BeatProcessor();
    init();

    connect(static_cast<BeatProcessor*>(m_processor), &BeatProcessor::beat, this, &BeatTracker::updateBpm);
}

smpl_t BeatTracker::bpm() const {
    return m_bpm;
}

void BeatTracker::updateBpm(smpl_t bpm) {
    if (!qFuzzyCompare(bpm + 1.0f, m_bpm + 1.0f)) {
        m_bpm = bpm;
        emit bpmChanged();
    }
}

} // namespace caelestia::shell::services
