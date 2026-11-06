#pragma once

#include <qqmlintegration.h>

#ifdef CAELESTIA_WINDOWS_AUDIO
// libcava is not part of the Windows toolchain; this module carries its own
// FFT/bar plan (CavaPlan) instead. The QML contract is unchanged.
#include "cavaplan.hpp"
#else
#include <cava/cavacore.h>
#endif

#include "audioprovider.hpp"

namespace caelestia::shell::services {

class CavaProcessor : public AudioProcessor {
    Q_OBJECT

public:
    explicit CavaProcessor(QObject* parent = nullptr);
    ~CavaProcessor() override;

    void setBars(int bars);

signals:
    void valuesChanged(QVector<double> values);

protected:
    void process() override;

private:
#ifdef CAELESTIA_WINDOWS_AUDIO
    ::caelestia::shell::windows::CavaPlan* m_plan;
#else
    struct cava_plan* m_plan;
#endif
    double* m_in;
    double* m_out;

    int m_bars;
    QVector<double> m_values;

    void reload();
    void initCava();
    void cleanup();
};

class CavaProvider : public AudioProvider {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(int bars READ bars WRITE setBars NOTIFY barsChanged)

    Q_PROPERTY(QVector<double> values READ values NOTIFY valuesChanged)

public:
    explicit CavaProvider(QObject* parent = nullptr);

    [[nodiscard]] int bars() const;
    void setBars(int bars);

    [[nodiscard]] QVector<double> values() const;

signals:
    void barsChanged();
    void valuesChanged();

private:
    int m_bars;
    QVector<double> m_values;

    void updateValues(const QVector<double>& values);
};

} // namespace caelestia::shell::services
