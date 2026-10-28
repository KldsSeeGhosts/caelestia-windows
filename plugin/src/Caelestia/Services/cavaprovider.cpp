#include "cavaprovider.hpp"

#include <qloggingcategory.h>

#ifndef CAELESTIA_WINDOWS_AUDIO
#include <cava/cavacore.h>
#endif

#include <algorithm>
#include <cstddef>

#include "audiocollector.hpp"
#include "audioprovider.hpp"

namespace {

Q_LOGGING_CATEGORY(lcCava, "caelestia.services.cava", QtInfoMsg)
Q_LOGGING_CATEGORY(lcCavaProcessor, "caelestia.services.cava.processor", QtInfoMsg)

constexpr int k_maxBars = 256; // Matches windows::CavaPlan::kMaxBars

} // namespace

namespace caelestia::shell::services {

CavaProcessor::CavaProcessor(QObject* parent)
    : AudioProcessor(parent)
    , m_plan(nullptr)
    , m_in(new double[ac::k_chunkSize])
    , m_out(nullptr)
    , m_bars(0) {};

CavaProcessor::~CavaProcessor() {
    cleanup();
    delete[] m_in;
}

void CavaProcessor::process() {
    if (!m_plan || m_bars == 0 || !m_out) {
        return;
    }

    const int count = static_cast<int>(AudioCollector::instance().readChunk(m_in));

#ifdef CAELESTIA_WINDOWS_AUDIO
    // Windows: run the ported FFT/bar plan instead of libcava.
    m_plan->execute(m_in, count, m_out);
#else
    // Process in data via cava
    cava_execute(m_in, count, m_out, m_plan);
#endif

    // Apply monstercat filter
    QVector<double> values(m_bars);

    // Left to right pass
    const double inv = 1.0 / 1.5;
    double carry = 0.0;
    for (int i = 0; i < m_bars; ++i) {
        carry = std::max(m_out[i], carry * inv);
        values[i] = carry;
    }

    // Right to left pass and combine
    carry = 0.0;
    for (int i = m_bars - 1; i >= 0; --i) {
        carry = std::max(m_out[i], carry * inv);
        values[i] = std::max(values[i], carry);
    }

    // Update values
    if (values != m_values) {
        m_values = std::move(values);
        emit valuesChanged(m_values);
    }
}

void CavaProcessor::setBars(int bars) {
    if (bars < 0) {
        qCWarning(lcCavaProcessor) << "setBars: bars must be greater than 0. Setting to 0.";
        bars = 0;
    }
    bars = std::min(bars, k_maxBars);

    if (m_bars != bars) {
        m_bars = bars;
        reload();
    }
}

void CavaProcessor::reload() {
    cleanup();
    initCava();
}

void CavaProcessor::cleanup() {
    if (m_plan) {
#ifdef CAELESTIA_WINDOWS_AUDIO
        delete m_plan;
#else
        cava_destroy(m_plan);
#endif
        m_plan = nullptr;
    }

    if (m_out) {
        delete[] m_out;
        m_out = nullptr;
    }
}

void CavaProcessor::initCava() {
    if (m_plan || m_bars == 0) {
        return;
    }

#ifdef CAELESTIA_WINDOWS_AUDIO
    m_plan = new ::caelestia::shell::windows::CavaPlan();
    m_plan->init(m_bars, ac::k_sampleRate, 0.85, 50, 10000);
#else
    m_plan = cava_init(m_bars, ac::k_sampleRate, 1, 1, 0.85, 50, 10000);
#endif
    m_out = new double[static_cast<size_t>(m_bars)];
}

CavaProvider::CavaProvider(QObject* parent)
    : AudioProvider(parent)
    , m_bars(0)
    , m_values(m_bars, 0.0) {
    m_processor = new CavaProcessor();
    init();

    connect(static_cast<CavaProcessor*>(m_processor), &CavaProcessor::valuesChanged, this, &CavaProvider::updateValues);
}

int CavaProvider::bars() const {
    return m_bars;
}

void CavaProvider::setBars(int bars) {
    if (bars < 0) {
        qCWarning(lcCava) << "setBars: bars must be greater than 0. Setting to 0.";
        bars = 0;
    }
    if (bars > k_maxBars) {
        qCWarning(lcCava) << "setBars: bars capped at" << k_maxBars;
        bars = k_maxBars;
    }

    if (m_bars == bars) {
        return;
    }

    m_values.resize(bars, 0.0);
    m_bars = bars;
    emit barsChanged();
    emit valuesChanged();

    QMetaObject::invokeMethod(
        static_cast<CavaProcessor*>(m_processor), &CavaProcessor::setBars, Qt::QueuedConnection, bars);
}

QVector<double> CavaProvider::values() const {
    return m_values;
}

void CavaProvider::updateValues(const QVector<double>& values) {
    if (values != m_values) {
        m_values = values;
        emit valuesChanged();
    }
}

} // namespace caelestia::shell::services
