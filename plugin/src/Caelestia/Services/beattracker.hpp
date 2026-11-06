#pragma once

#include <qqmlintegration.h>

#ifdef CAELESTIA_WINDOWS_AUDIO
// aubio is not part of the Windows toolchain; the Windows module provides a
// spectral-flux onset/tempo detector behind the same QML contract.
#include "onsetdetector.hpp"

using smpl_t = float;
#else
#include <aubio/aubio.h>
#endif

#include "audioprovider.hpp"

namespace caelestia::shell::services {

class BeatProcessor : public AudioProcessor {
    Q_OBJECT

public:
    explicit BeatProcessor(QObject* parent = nullptr);
    ~BeatProcessor() override;

signals:
    void beat(smpl_t bpm);

protected:
    void process() override;

private:
#ifdef CAELESTIA_WINDOWS_AUDIO
    ::caelestia::shell::windows::OnsetDetector m_detector;
    float* m_in;
#else
    aubio_tempo_t* m_tempo;
    fvec_t* m_in;
    fvec_t* m_out;
#endif
};

class BeatTracker : public AudioProvider {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(smpl_t bpm READ bpm NOTIFY bpmChanged)

public:
    explicit BeatTracker(QObject* parent = nullptr);

    [[nodiscard]] smpl_t bpm() const;

signals:
    void bpmChanged();
    void beat(smpl_t bpm);

private:
    smpl_t m_bpm;

    void updateBpm(smpl_t bpm);
};

} // namespace caelestia::shell::services
