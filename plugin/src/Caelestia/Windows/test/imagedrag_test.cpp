#include <memory>

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qguiapplication.h>
#include <qimage.h>
#include <qmimedata.h>
#include <qobject.h>
#include <qpainter.h>
#include <qtemporarydir.h>
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
    QString save(const QImage& image, const QString& name) {
        const auto path = dir.filePath(name);
        [&] { QVERIFY(image.save(path)); }();
        return path;
    }

    QTemporaryDir dir;
};

QTEST_MAIN(ImageDragTest)
#include "imagedrag_test.moc"
