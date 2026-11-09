// Windows data object test for the thumbnail's drag. It needs Qt's real
// "windows" platform plugin (not offscreen), so it is built only with
// -DCAELESTIA_WINDOWS_DESKTOP_TESTS=ON and is not registered with CTest. No CI
// gate runs it.
//
// A drag hands the target a data object that Qt builds around the QMimeData. Qt
// builds the same object for the clipboard, so the test puts the drag's data on
// the clipboard, reads it back through OLE (OleGetClipboard) and decodes every
// format that a drop target would be offered: CF_HDROP, PNG, CF_DIB, CF_DIBV5
// and "Preferred DropEffect". THE TEST REPLACES THE CLIPBOARD CONTENT, and
// empties it at the end, as the Rust tool's desktop tests did.
//
// What this cannot show is a drop into another program. That, the copy-only
// effect on the wire and the drag picture are the owner's live checks (Explorer,
// a browser, Paint, Word). A scripted press and release did not end Qt's
// DoDragDrop on a synthetic window reliably, so no pointer is injected here.

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qguiapplication.h>
#include <qclipboard.h>
#include <qimage.h>
#include <qtemporarydir.h>
#include <qtest.h>

#include <objbase.h>
#include <ole2.h>
#include <qt_windows.h>
#include <shellapi.h>
#include <shlobj.h>

#include "../../imagedrag.hpp"

namespace {

using namespace caelestia::shell;

QString formatName(CLIPFORMAT format) {
    switch (format) {
    case CF_BITMAP: return QStringLiteral("CF_BITMAP");
    case CF_DIB: return QStringLiteral("CF_DIB");
    case CF_DIBV5: return QStringLiteral("CF_DIBV5");
    case CF_HDROP: return QStringLiteral("CF_HDROP");
    case CF_UNICODETEXT: return QStringLiteral("CF_UNICODETEXT");
    case CF_TEXT: return QStringLiteral("CF_TEXT");
    default: break;
    }
    wchar_t name[128] = {};
    if (GetClipboardFormatNameW(format, name, int(std::size(name))) > 0)
        return QString::fromWCharArray(name);
    return QStringLiteral("#%1").arg(format);
}

CLIPFORMAT registered(const wchar_t* name) {
    return CLIPFORMAT(RegisterClipboardFormatW(name));
}

QByteArray bytesOf(IDataObject* data, CLIPFORMAT format) {
    FORMATETC wanted = { format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };
    STGMEDIUM medium = {};
    if (FAILED(data->GetData(&wanted, &medium)))
        return {};
    QByteArray bytes;
    if (medium.tymed == TYMED_HGLOBAL) {
        if (const auto* memory = static_cast<const char*>(GlobalLock(medium.hGlobal))) {
            bytes = QByteArray(memory, int(GlobalSize(medium.hGlobal)));
            GlobalUnlock(medium.hGlobal);
        }
    }
    ReleaseStgMedium(&medium);
    return bytes;
}

// A device independent bitmap as a BMP file, so Qt's reader can decode it.
QImage imageFromDib(const QByteArray& dib) {
    if (dib.size() < int(sizeof(BITMAPINFOHEADER)))
        return {};
    const auto* header = reinterpret_cast<const BITMAPINFOHEADER*>(dib.constData());
    quint32 colours = header->biClrUsed;
    if (colours == 0 && header->biBitCount <= 8)
        colours = 1u << header->biBitCount;
    const quint32 masks = header->biCompression == BI_BITFIELDS && header->biSize == sizeof(BITMAPINFOHEADER) ? 12 : 0;
    BITMAPFILEHEADER file = {};
    file.bfType = 0x4d42;
    file.bfSize = quint32(sizeof(BITMAPFILEHEADER) + dib.size());
    file.bfOffBits = quint32(sizeof(BITMAPFILEHEADER)) + header->biSize + masks + colours * 4;
    QByteArray bmp(reinterpret_cast<const char*>(&file), sizeof(file));
    bmp.append(dib);
    return QImage::fromData(bmp, "BMP");
}

// A distinctive picture: a gradient with a different colour in each corner.
QImage picture() {
    QImage image(320, 180, QImage::Format_ARGB32);
    for (int y = 0; y < image.height(); y++) {
        for (int x = 0; x < image.width(); x++)
            image.setPixelColor(x, y, QColor(x * 255 / 319, y * 255 / 179, 128));
    }
    image.setPixelColor(0, 0, Qt::red);
    image.setPixelColor(319, 0, Qt::green);
    image.setPixelColor(0, 179, Qt::blue);
    image.setPixelColor(319, 179, Qt::white);
    return image;
}

} // namespace

class ImageDragDataObjectTest : public QObject {
    Q_OBJECT

private slots:
    void windowsDeliversTheFileAndTheImage() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const auto original = picture();
        const auto path = dir.filePath(QStringLiteral("annotate-test.png"));
        QVERIFY(original.save(path));
        const auto sizeBefore = QFileInfo(path).size();

        auto mime = imagedrag::mimeData(path);
        QVERIFY(mime);
        QGuiApplication::clipboard()->setMimeData(mime.release());
        QCoreApplication::processEvents();

        IDataObject* data = nullptr;
        QCOMPARE(OleGetClipboard(&data), S_OK);
        QVERIFY(data);

        QStringList formats;
        IEnumFORMATETC* list = nullptr;
        QCOMPARE(data->EnumFormatEtc(DATADIR_GET, &list), S_OK);
        FORMATETC format;
        while (list->Next(1, &format, nullptr) == S_OK)
            formats << formatName(format.cfFormat);
        list->Release();
        qInfo().noquote() << "formats offered to a drop target:" << formats.join(QStringLiteral(", "));

        // CF_HDROP: the real file, by its own path.
        QVERIFY2(formats.contains(QStringLiteral("CF_HDROP")), "no CF_HDROP");
        FORMATETC hdrop = { CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL };
        STGMEDIUM medium = {};
        QCOMPARE(data->GetData(&hdrop, &medium), S_OK);
        const auto drop = reinterpret_cast<HDROP>(medium.hGlobal);
        QCOMPARE(DragQueryFileW(drop, 0xffffffff, nullptr, 0), UINT(1));
        wchar_t file[MAX_PATH] = {};
        DragQueryFileW(drop, 0, file, MAX_PATH);
        ReleaseStgMedium(&medium);
        QCOMPARE(QDir::fromNativeSeparators(QString::fromWCharArray(file)), QDir::fromNativeSeparators(path));

        // PNG: what Discord, a browser or Word read as an image.
        QVERIFY2(formats.contains(QStringLiteral("PNG")), "no PNG format");
        const auto png = QImage::fromData(bytesOf(data, registered(L"PNG")), "PNG");
        QVERIFY(!png.isNull());
        QCOMPARE(png.size(), original.size());
        QCOMPARE(png.convertToFormat(QImage::Format_ARGB32), original);

        // CF_DIB: what Paint reads.
        QVERIFY2(formats.contains(QStringLiteral("CF_DIB")), "no CF_DIB");
        const auto dib = imageFromDib(bytesOf(data, CF_DIB));
        QVERIFY(!dib.isNull());
        QCOMPARE(dib.size(), original.size());
        QCOMPARE(dib.pixelColor(0, 0).rgb(), original.pixelColor(0, 0).rgb());
        QCOMPARE(dib.pixelColor(319, 179).rgb(), original.pixelColor(319, 179).rgb());

        QVERIFY2(formats.contains(QStringLiteral("CF_DIBV5")), "no CF_DIBV5");
        const auto dibV5 = imageFromDib(bytesOf(data, CF_DIBV5));
        QVERIFY(!dibV5.isNull());
        QCOMPARE(dibV5.size(), original.size());

        // Copy is the preferred effect.
        QVERIFY2(formats.contains(QStringLiteral("Preferred DropEffect")), "no Preferred DropEffect");
        const auto effect = bytesOf(data, registered(L"Preferred DropEffect"));
        QCOMPARE(effect.size(), 4);
        QCOMPARE(quint8(effect[0]), quint8(DROPEFFECT_COPY));

        data->Release();
        QGuiApplication::clipboard()->clear();

        // Offering the data reads the file and leaves it as it was.
        QVERIFY(QFile::exists(path));
        QCOMPARE(QFileInfo(path).size(), sizeBefore);
        QCOMPARE(QDir(dir.path()).entryList(QDir::Files).size(), 1);
    }
};

QTEST_MAIN(ImageDragDataObjectTest)
#include "imagedrag_desktop_test.moc"
