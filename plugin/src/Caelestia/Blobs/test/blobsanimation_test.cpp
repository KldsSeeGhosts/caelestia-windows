#include "blobgroup.hpp"
#include "blobrect.hpp"

#include <qcoreapplication.h>
#include <qtest.h>

using namespace caelestia::shell::blobs;

namespace {
// Drive the scheduler without wall-clock-dependent spring integration.
class Shape : public BlobRect {
public:
    int physicsPasses = 0;
    void request() {
        m_physicsActive = true;
        group()->requestAnimationTurn();
    }
    void settle() { m_physicsActive = false; }
    void updatePhysics() override { ++physicsPasses; }
};

class Group : public BlobGroup {
public:
    int deliveries = 0;
    void flush() {
        QCoreApplication::sendPostedEvents(this, QEvent::MetaCall);
        ensurePhysicsUpdated();
    }
    bool event(QEvent* event) override {
        if (event->type() == QEvent::MetaCall)
            ++deliveries;
        return BlobGroup::event(event);
    }
};
}

class BlobsAnimationTest : public QObject {
    Q_OBJECT
private slots:
    void coalescesAndRearms() {
        Group group;
        Shape a, b;
        a.setGroup(&group);
        b.setGroup(&group);
        group.flush();
        for (int turn = 1; turn <= 2; ++turn) {
            a.request();
            b.request();
            a.request();
            group.flush();
            QCOMPARE(group.deliveries, turn);
            QCOMPARE(a.physicsPasses, turn + 1);
            QCOMPARE(b.physicsPasses, turn + 1);
        }
        a.request();
        a.settle();
        b.settle();
        group.flush();
        QCOMPARE(a.physicsPasses, 3); // Resting group did not restart.
    }

    void membershipAtDelivery() {
        Group first, second;
        Shape peer, moving;
        peer.setGroup(&first);
        moving.setGroup(&first);
        moving.request();
        moving.setGroup(&second);
        {
            Shape closed;
            closed.setGroup(&first);
            closed.request();
        }
        first.ensurePhysicsUpdated(); // Membership changes already dirtied the group.
        const int previous = peer.physicsPasses;
        first.flush();
        QCOMPARE(peer.physicsPasses, previous);
        second.flush();
        QCOMPARE(moving.physicsPasses, 1);
        moving.request();
        second.flush();
        QCOMPARE(moving.physicsPasses, 2);
    }

    void destroyedGroupCancelsQueuedTurn() {
        Shape survivor;
        {
            Group group;
            survivor.setGroup(&group);
            survivor.request();
        }
        QCoreApplication::sendPostedEvents(nullptr, QEvent::MetaCall);
        QVERIFY(!survivor.group());
    }
};

QTEST_GUILESS_MAIN(BlobsAnimationTest)
#include "blobsanimation_test.moc"
