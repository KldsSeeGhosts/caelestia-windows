#include <functional>
#include <memory>

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qdrag.h>
#include <qevent.h>
#include <qeventloop.h>
#include <qguiapplication.h>
#include <qimage.h>
#include <qmimedata.h>
#include <qobject.h>
#include <qpainter.h>
#include <qpointer.h>
#include <qtemporarydir.h>
#include <qtimer.h>
#include <qtest.h>
#include <qurl.h>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

#include "../../imagedrag.hpp"

namespace {

using namespace caelestia::shell;

// A small image with one differently coloured pixel in each corner, so a flipped
// or cropped copy is noticed.
QImage sample(int width = 40, int height = 24) {
    QImage image(width, height, QImage::Format_ARGB32);
    image.fill(QColor(30, 60, 90));
    image.setPixelColor(0, 0, Qt::red);
    image.setPixelColor(width - 1, 0, Qt::green);
    image.setPixelColor(0, height - 1, Qt::blue);
    image.setPixelColor(width - 1, height - 1, Qt::white);
    return image;
}

} // namespace

class ImageDragTest : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() { QVERIFY(dir.isValid()); }

    // The drag offers the real file, so a target that wants a file gets the one
    // on disk and not a copy made for the drag.
    void offersTheFileItself() {
        const auto path = save(sample(), QStringLiteral("shot.png"));
        const auto data = imagedrag::mimeData(path);
        QVERIFY(data);
        QVERIFY(data->hasUrls());
        QCOMPARE(data->urls().size(), 1);
        QCOMPARE(data->urls().constFirst(), QUrl::fromLocalFile(path));
        QCOMPARE(data->urls().constFirst().toLocalFile(), path);
        QVERIFY(data->hasFormat(QStringLiteral("text/uri-list")));
    }

    // The decoded image is what Qt's Windows converters turn into PNG, CF_DIB
    // and CF_DIBV5. This is the image data, unchanged.
    void offersTheDecodedImage() {
        const auto original = sample();
        const auto data = imagedrag::mimeData(save(original, QStringLiteral("image.png")));
        QVERIFY(data);
        QVERIFY(data->hasImage());
        const auto image = qvariant_cast<QImage>(data->imageData());
        QCOMPARE(image.size(), original.size());
        QCOMPARE(image.convertToFormat(QImage::Format_ARGB32), original);
    }

    // Offers a file and an image and nothing else: no text, no HTML.
    void offersOnlyTheFileAndTheImage() {
        const auto data = imagedrag::mimeData(save(sample(), QStringLiteral("only.png")));
        QVERIFY(data);
        // (hasText() is true for a URL list, so look at the formats themselves.)
        QVERIFY(!data->hasFormat(QStringLiteral("text/plain")));
        QVERIFY(!data->hasHtml());
        QVERIFY(!data->hasColor());
        for (const auto& format : data->formats()) {
            const bool known = format == QStringLiteral("text/uri-list") || format == QStringLiteral("application/x-qt-image")
                || format.startsWith(QStringLiteral("application/x-qt-windows-mime;value="));
            QVERIFY2(known, qPrintable(format));
        }
    }

#ifdef Q_OS_WIN
    // Explorer and several editors read this to choose between copy and move.
    void prefersCopyOnWindows() {
        const auto data = imagedrag::mimeData(save(sample(), QStringLiteral("effect.png")));
        QVERIFY(data);
        const auto bytes = data->data(QStringLiteral("application/x-qt-windows-mime;value=\"Preferred DropEffect\""));
        QCOMPARE(bytes.size(), 4);
        QCOMPARE(quint32(quint8(bytes[0])) | quint32(quint8(bytes[1])) << 8 | quint32(quint8(bytes[2])) << 16
                | quint32(quint8(bytes[3])) << 24,
            quint32(1));
    }
#endif

    void refusesWhatIsNotAnImageFile() {
        QVERIFY(!imagedrag::mimeData(QString()));
        QVERIFY(!imagedrag::mimeData(QStringLiteral("shot.png")));
        QVERIFY(!imagedrag::mimeData(dir.filePath(QStringLiteral("missing.png"))));
        QVERIFY(!imagedrag::mimeData(dir.path()));

        QFile text(dir.filePath(QStringLiteral("text.png")));
        QVERIFY(text.open(QIODevice::WriteOnly));
        text.write("this is not a PNG");
        text.close();
        QVERIFY(!imagedrag::mimeData(text.fileName()));

        QFile empty(dir.filePath(QStringLiteral("empty.png")));
        QVERIFY(empty.open(QIODevice::WriteOnly));
        empty.close();
        QVERIFY(!imagedrag::mimeData(empty.fileName()));
    }

    // Making the data never writes, moves or deletes the file.
    void leavesTheFileAlone() {
        const auto path = save(sample(), QStringLiteral("keep.png"));
        const auto before = QFileInfo(path).lastModified();
        const auto size = QFileInfo(path).size();
        { const auto data = imagedrag::mimeData(path); QVERIFY(data); }
        QVERIFY(QFile::exists(path));
        QCOMPARE(QFileInfo(path).size(), size);
        QCOMPARE(QFileInfo(path).lastModified(), before);
        QCOMPARE(QDir(dir.path()).entryList({ QStringLiteral("keep*") }).size(), 1);
    }

    // The picture under the pointer is the thumbnail's image: the same aspect,
    // the logical size of the item and the device pixels of its window.
    void previewFitsTheThumbnailImage() {
        const auto data = imagedrag::mimeData(save(sample(40, 24), QStringLiteral("p1.png")));
        const auto look = imagedrag::preview(*data, QSizeF(20, 12), 1.0);
        QCOMPARE(look.pixmap.size(), QSize(20, 12));
        QCOMPARE(look.pixmap.devicePixelRatio(), 1.0);
        QCOMPARE(look.hotSpot, QPoint(10, 6));

        const auto scaled = imagedrag::preview(*data, QSizeF(20, 12), 1.5);
        QCOMPARE(scaled.pixmap.size(), QSize(30, 18));
        QCOMPARE(scaled.pixmap.devicePixelRatio(), 1.5);
        QCOMPARE(scaled.hotSpot, QPoint(10, 6));
    }

    void previewKeepsTheImageAspect() {
        const auto data = imagedrag::mimeData(save(sample(40, 24), QStringLiteral("p2.png")));
        // A box that is wider than the image: the height decides.
        const auto look = imagedrag::preview(*data, QSizeF(100, 12), 1.0);
        QCOMPARE(look.pixmap.height(), 12);
        QVERIFY(look.pixmap.width() <= 100);
        QCOMPARE(look.pixmap.width(), 20);
    }

    void previewWithoutASizeUsesTheImage() {
        const auto small = imagedrag::mimeData(save(sample(40, 24), QStringLiteral("p3.png")));
        QCOMPARE(imagedrag::preview(*small, QSizeF(), 1.0).pixmap.size(), QSize(40, 24));
        QCOMPARE(imagedrag::preview(*small, QSizeF(0, 50), 1.0).pixmap.size(), QSize(40, 24));

        const auto big = imagedrag::mimeData(save(sample(1024, 512), QStringLiteral("p4.png")));
        const auto look = imagedrag::preview(*big, QSizeF(), 1.0);
        QCOMPARE(look.pixmap.size(), QSize(256, 128));
        QCOMPARE(look.hotSpot, QPoint(128, 64));
    }

    void previewIgnoresABadScale() {
        const auto data = imagedrag::mimeData(save(sample(40, 24), QStringLiteral("p5.png")));
        QCOMPARE(imagedrag::preview(*data, QSizeF(20, 12), 0.0).pixmap.size(), QSize(20, 12));
        QCOMPARE(imagedrag::preview(*data, QSizeF(20, 12), -2.0).pixmap.devicePixelRatio(), 1.0);
    }

    void previewOfNothingIsEmpty() {
        QMimeData empty;
        QVERIFY(imagedrag::preview(empty, QSizeF(20, 12), 1.0).pixmap.isNull());
    }

    // No drag runs without data or without a source object.
    void doesNotRunWithoutDataOrSource() {
        QObject source;
        QVERIFY(!imagedrag::run(nullptr, {}, &source).has_value());
        const auto data = imagedrag::mimeData(save(sample(), QStringLiteral("run.png")));
        QVERIFY(data);
        QVERIFY(!imagedrag::run(imagedrag::mimeData(save(sample(), QStringLiteral("run2.png"))), {}, nullptr).has_value());
    }

    // The drag runs a nested event loop (OLE's on Windows). What a shell reload
    // does to the object that asked for the drag must not free the drag, its data
    // or its picture while that loop runs, and the data must be freed exactly once,
    // after the loop has returned. The offscreen platform has no pointer and its
    // drag returns at once, so most cases pass `exec`, which runs an event loop of
    // the test's own in place of the system's.


    // With the real exec the offscreen platform has no drag, and Qt frees the
    // drag itself by deleteLater. Nothing may be left to run afterwards.
    void theRealExecLeavesNothingToFreeLater() {
        int freed = 0;
        QObject source;
        const auto action = imagedrag::run(std::make_unique<Tracked>(&freed), pixmapPreview(), &source);
        QVERIFY(action.has_value());
        QCOMPARE(freed, 1);
        QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
        QCoreApplication::processEvents();
        QCOMPARE(freed, 1);
    }

    // The source is deleted inside the loop, as a reload does. Nothing under the
    // drag is freed until the loop has returned.
    void destroyingTheSourceMidDragFreesNothingUnderTheDrag() {
        int freed = 0;
        auto* source = new QObject;
        int freedInLoop = -1;
        bool dataAlive = false, picture = false;
        const auto action = imagedrag::run(std::make_unique<Tracked>(&freed), pixmapPreview(), source,
            loop([&](QDrag& drag) {
                delete source;
                QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
                freedInLoop = freed;
                dataAlive = drag.mimeData() && drag.mimeData()->text() == QStringLiteral("tracked");
                picture = !drag.pixmap().isNull();
            }));
        QVERIFY(action.has_value());
        QCOMPARE(*action, Qt::IgnoreAction);
        QCOMPARE(freedInLoop, 0);
        QVERIFY(dataAlive);
        QVERIFY(picture);
        QCOMPARE(freed, 1);
    }

    // The deferred deletion that QML objects get (deleteLater), delivered inside
    // the loop.
    void aDeferredDeletionOfTheSourceMidDragIsSafe() {
        int freed = 0;
        auto* source = new QObject;
        QPointer<QObject> guard(source);
        int freedInLoop = -1;
        bool dataAlive = false;
        const auto action = imagedrag::run(std::make_unique<Tracked>(&freed), pixmapPreview(), source,
            loop([&](QDrag& drag) {
                source->deleteLater();
                QCoreApplication::sendPostedEvents(source, QEvent::DeferredDelete);
                QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
                freedInLoop = freed;
                dataAlive = drag.mimeData() && drag.mimeData()->hasText();
            }));
        QVERIFY(action.has_value());
        QVERIFY(guard.isNull());
        QCOMPARE(freedInLoop, 0);
        QVERIFY(dataAlive);
        QCOMPARE(freed, 1);
    }

    // The source goes away together with an object tree that parents it, as a
    // reload tears down the engine's objects.
    void destroyingTheOwnersParentMidDragIsSafe() {
        int freed = 0;
        auto* root = new QObject;
        auto* source = new QObject(root);
        new QObject(source);
        int freedInLoop = -1;
        const auto action = imagedrag::run(std::make_unique<Tracked>(&freed), pixmapPreview(), source,
            loop([&](QDrag&) {
                delete root;
                freedInLoop = freed;
            }));
        QVERIFY(action.has_value());
        QCOMPARE(freedInLoop, 0);
        QCOMPARE(freed, 1);
    }

    // A second request that arrives inside the loop is refused and does not
    // disturb the first. The guard is released when the first returns.
    void aSecondDragInsideTheLoopIsRefusedAndTheNextOneRuns() {
        int freed = 0, freedSecond = 0;
        QObject source;
        std::optional<std::optional<Qt::DropAction>> inner;
        const auto action = imagedrag::run(std::make_unique<Tracked>(&freed), pixmapPreview(), &source,
            loop([&](QDrag&) {
                inner = imagedrag::run(std::make_unique<Tracked>(&freedSecond), {}, &source);
            }));
        QVERIFY(action.has_value());
        QVERIFY(inner.has_value() && !inner->has_value());
        QCOMPARE(freedSecond, 1);
        QCOMPARE(freed, 1);

        int freedThird = 0;
        QVERIFY(imagedrag::run(std::make_unique<Tracked>(&freedThird), {}, &source).has_value());
        QCOMPARE(freedThird, 1);
    }

    // The drag loop leaves by an exception: the data is still freed and the next
    // drag can start.
    void anExceptionInTheLoopFreesEverythingAndReleasesTheGuard() {
        int freed = 0;
        QObject source;
        bool threw = false;
        try {
            imagedrag::run(std::make_unique<Tracked>(&freed), pixmapPreview(), &source, [](QDrag&) -> Qt::DropAction {
                throw 7;
            });
        } catch (int) {
            threw = true;
        }
        QVERIFY(threw);
        QCOMPARE(freed, 1);
        int freedNext = 0;
        QVERIFY(imagedrag::run(std::make_unique<Tracked>(&freedNext), {}, &source).has_value());
        QCOMPARE(freedNext, 1);
    }

    void dragDistanceIsAtLeastOnePixel() {
        const auto distance = imagedrag::dragDistance();
        QVERIFY(distance.width() >= 1);
        QVERIFY(distance.height() >= 1);
#ifdef Q_OS_WIN
        QCOMPARE(distance.width(), qMax(1, int(GetSystemMetrics(SM_CXDRAG))));
        QCOMPARE(distance.height(), qMax(1, int(GetSystemMetrics(SM_CYDRAG))));
#endif
    }

private:
    // Mime data that counts how often it is freed.
    class Tracked : public QMimeData {
    public:
        explicit Tracked(int* freed) : freed(freed) { setText(QStringLiteral("tracked")); }
        ~Tracked() override { ++*freed; }

    private:
        int* freed;
    };

    // Spins an event loop for the length of the "drag", with `during` running
    // inside it, as the system's loop would be running.
    static std::function<Qt::DropAction(QDrag&)> loop(std::function<void(QDrag&)> during) {
        return [during = std::move(during)](QDrag& drag) {
            QEventLoop nested;
            QTimer::singleShot(30, &nested, [&] {
                during(drag);
                nested.quit();
            });
            nested.exec();
            return Qt::IgnoreAction;
        };
    }
    imagedrag::Preview pixmapPreview() {
        imagedrag::Preview look;
        look.pixmap = QPixmap::fromImage(sample());
        look.hotSpot = QPoint(5, 5);
        return look;
    }

    QString save(const QImage& image, const QString& name) {
        const auto path = dir.filePath(name);
        [&] { QVERIFY(image.save(path)); }();
        return path;
    }

    QTemporaryDir dir;
};

QTEST_MAIN(ImageDragTest)
#include "imagedrag_test.moc"
