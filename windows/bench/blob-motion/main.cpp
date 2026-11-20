// Two unshown Qt Quick windows. Run the real polish and spring code; never
// render, inject input, or attach a hook to the user's desktop.
#include <QGuiApplication>
#include <QQuickRenderControl>
#include <QQuickWindow>
#include <QThread>
#include <algorithm>
#include <array>
#include <cstdio>
#include "blobgroup.hpp"
#include "blobinvertedrect.hpp"
#include "blobrect.hpp"

using namespace caelestia::shell::blobs;

struct Counter : QObject {
    int deliveries = 0;
    bool eventFilter(QObject*, QEvent* event) override {
        if (event->type() == QEvent::MetaCall)
            ++deliveries;
        return false;
    }
};

struct Drawer {
    QQuickRenderControl control;
    QQuickWindow window{&control};
    Counter counter;
    BlobGroup group;
    BlobInvertedRect border{window.contentItem()};
    std::array<BlobRect, 9> panels;

    Drawer() {
        group.installEventFilter(&counter);
        border.setSize({1920, 1080});
        border.setGroup(&group);
        for (int i = 0; i < int(panels.size()); ++i) {
            auto& panel = panels[i];
            panel.setParentItem(window.contentItem());
            panel.setSize({300, 170});
            panel.setPosition({double(i * 100), double(i * 30)});
            panel.setGroup(&group);
            panel.installEventFilter(&counter);
        }
    }
};

int main(int argc, char** argv) {
    QGuiApplication app(argc, argv);
    std::array<Drawer, 2> drawers;
    const auto tick = [&] {
        for (auto& drawer : drawers)
            drawer.control.polishItems();
        QCoreApplication::sendPostedEvents(nullptr, QEvent::MetaCall);
    };
    const auto deliveries = [&] { return drawers[0].counter.deliveries + drawers[1].counter.deliveries; };
    for (int moving : {1, 4}) {
        tick();
        const int before = deliveries();
        int peakMoving = 0;
        for (int i = 0; i < 32; ++i) {
            QThread::msleep(12); // The production spring samples elapsed wall time.
            for (auto& drawer : drawers)
                for (int j = 0; j < moving; ++j)
                    drawer.panels[j].setX(drawer.panels[j].x() + 5);
            tick();
            int active = 0;
            for (auto& drawer : drawers)
                for (auto& panel : drawer.panels)
                    active += !panel.rawDeformMatrix().isIdentity();
            peakMoving = std::max(peakMoving, active);
        }
        const int travel = deliveries() - before;
        int quietTicks = 0;
        for (int i = 0; i < 200 && quietTicks < 4; ++i) {
            QThread::msleep(12);
            const int last = deliveries();
            tick();
            quietTicks = deliveries() == last ? quietTicks + 1 : 0;
        }
        bool atRest = true;
        for (auto& drawer : drawers)
            for (auto& panel : drawer.panels)
                atRest &= panel.rawDeformMatrix().isIdentity();
        std::printf("screens=2 steps=32 moving_per_screen=%d peak_deformed=%d motion_callbacks=%d settled=%d\n",
            moving, peakMoving, travel, atRest && quietTicks == 4);
        if (peakMoving != 2 * moving || !travel || !atRest || quietTicks != 4)
            return 1;
    }
}
