// Synthetic identities, real production layout and foreground-observer code.
// No window, hook, activation, input, provider or live session is started.
#include <iostream>
#include <qcoreapplication.h>
#include <qelapsedtimer.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qrandom.h>
#include <malloc.h>
#include <vector>
#include "tiling_layout.hpp"
#include "foreground_observer.hpp"
#include "window_tracker.hpp"
#include "system_surface.hpp"

namespace { quint64 eventSequence = 0; }
namespace qs::windows {
// Same safe fake-tracker boundary as foreground_observer_test.cpp.
WindowTracker::WindowTracker() = default;
WindowTracker::~WindowTracker() = default;
WindowTracker* WindowTracker::instance() { static WindowTracker tracker; return &tracker; }
quint64 WindowTracker::eventSequence() const { return ::eventSequence; }
bool isOwnProcessWindow(HWND) { return false; }
namespace system_surface {
Identity observe(HWND hwnd) {
    Identity result;
    result.root = result.visible = result.hasTitle = true;
    result.title = QString::number(reinterpret_cast<quintptr>(hwnd));
    result.processName = QStringLiteral("probe.exe");
    return result;
}
bool isShellSurface(const Identity&) { return false; }
bool isDesktopSurface(const Identity&) { return false; }
}
}

Q_NEVER_INLINE int runBench(int argc, char** argv, int stackPadBytes, int heapPadBytes) {
    QCoreApplication app(argc, argv);
    const auto args = app.arguments();
    const bool plant = args.contains(QStringLiteral("--plant=1"));
    const double plantPercent = qEnvironmentVariable("CAELESTIA_BENCH_PLANT_PERCENT", "25").toDouble();
    if (!args.contains(QStringLiteral("--plant=0")) && !plant) return 3;
    if (plantPercent < 0 || plantPercent > 100) return 3;
    const QString area = args.value(1);
    const int operations = 500000;
    const int warmup = operations;
    const int actual = operations + (plant ? qRound(operations * plantPercent / 100) : 0);
    qint64 checksum = 0;
    ULONGLONG cyclesBefore = 0, cyclesAfter = 0;
    QElapsedTimer timer;
    if (area == "tiling") {
        qs::windows::tiling::DwindleLayout layout;
        for (quintptr id = 1; id <= 32; ++id) layout.insert(id, id - 1, nullptr);
        layout.compute(QRect(0, 0, 1920, 1080));
        timer.start();
        for (int i = -warmup; i < actual; ++i) {
            if (i == 0) {
                if (!QueryThreadCycleTime(GetCurrentThread(), &cyclesBefore)) return 4;
                timer.restart();
            }
            layout.compute(QRect(0, 0, 1920 + (i & 1), 1080));
            checksum += layout.box(1).width();
        }
    } else if (area == "tracker") {
        qs::windows::Foreground foreground;
        QObject::connect(&foreground, &qs::windows::Foreground::foregroundChanged,
                         &app, [&checksum](qulonglong, uint, qulonglong) { ++checksum; });
        timer.start();
        for (int i = -warmup; i < actual; ++i) {
            if (i == 0) {
                if (!QueryThreadCycleTime(GetCurrentThread(), &cyclesBefore)) return 4;
                timer.restart();
            }
            ::eventSequence++;
            emit qs::windows::WindowTracker::instance()->foregroundEvent(
                reinterpret_cast<HWND>(quintptr(1 + (i & 1))), uint(i), ::eventSequence);
        }
    } else { return 1; }
    const auto ns = timer.nsecsElapsed();
    if (!QueryThreadCycleTime(GetCurrentThread(), &cyclesAfter) || cyclesAfter <= cyclesBefore) return 4;
    if (checksum <= 0 || ns <= 0) return 2;
    QJsonObject out{{"elapsedNs", double(ns)}, {"operations", operations},
                    {"cpuCycles", double(cyclesAfter - cyclesBefore)},
                    {"warmupOperations", warmup},
                    {"stackPadBytes", stackPadBytes}, {"heapPadBytes", heapPadBytes},
                    {"plantPercent", plant ? plantPercent : 0},
                    {"actualOperations", actual}, {"checksum", double(checksum)},
                    {"nanosecondsPerOperation", double(ns) / operations},
                    {"cyclesPerOperation", double(cyclesAfter - cyclesBefore) / operations}};
    std::cout << QJsonDocument(out).toJson(QJsonDocument::Compact).toStdString() << '\n';
    return 0;
}

int main(int argc, char** argv) {
    // Re-sample process layout, not CPU affinity. Many short independent
    // processes expose slow-layout modes instead of averaging one mode forever.
    const int stackPadBytes = 64 * (1 + QRandomGenerator::system()->bounded(1024));
    const int heapPadBytes = 64 * (1 + QRandomGenerator::system()->bounded(16384));
    volatile char* stackPad = static_cast<volatile char*>(_alloca(stackPadBytes));
    for (int i = 0; i < stackPadBytes; i += 64) stackPad[i] = char(i);
    std::vector<char> heapPad(heapPadBytes, 1);
    const int result = runBench(argc, argv, stackPadBytes, heapPadBytes);
    return result + (stackPad[0] != 0 || heapPad[0] != 1);
}
