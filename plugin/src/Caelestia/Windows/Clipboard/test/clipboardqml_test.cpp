// Regression for the picker showing no rows while the backend held entries.
//
// WindowsClipboard::items is a native QVariantList. QML hands that to JS as an
// array-like sequence wrapper for which Array.isArray() is false, and the
// display model once rejected anything that was not a real Array. The JS
// tests only ever used literal arrays, so they could not see it. This test
// sends real QVariantList data through the same chain the shell uses (native
// property, wrapper `property var`, facade `property var`) into the shipped
// ClipboardHistory.js.

#include <memory>

#include <qcoreapplication.h>
#include <qobject.h>
#include <qqmlcomponent.h>
#include <qqmlengine.h>
#include <qstring.h>
#include <qurl.h>
#include <qvariant.h>

#include <QtTest/QtTest>

namespace {

// Same shape as WindowsClipboard::items: a QVariantList of QVariantMap.
class NativeHistory : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList items READ items NOTIFY itemsChanged)

public:
    [[nodiscard]] QVariantList items() const { return m_items; }

    void setItems(const QVariantList& items) {
        m_items = items;
        emit itemsChanged();
    }

signals:
    void itemsChanged();

private:
    QVariantList m_items;
};

QVariantMap entry(const QString& id, const QString& text) {
    return { { QStringLiteral("id"), id }, { QStringLiteral("kind"), QStringLiteral("text") },
        { QStringLiteral("text"), text } };
}

// Mirrors NativeClipboardBackend.qml (wrapper) and ClipboardHistory.qml
// (facade): each hop is a `var` property, as in the shell.
const char* const harness = R"(
import QtQml
import "ClipboardHistory.js" as Rows

QtObject {
    id: root

    property QtObject service
    readonly property var wrapped: service.items
    property var facade: []

    property Connections sync: Connections {
        target: root.service
        function onItemsChanged(): void {
            root.facade = root.wrapped;
        }
    }

    function facadeIsArray(): bool {
        return Array.isArray(root.facade);
    }

    function ids(query: string): string {
        return Rows.displayRows(root.facade, query, 60).map(row => row.itemId).join(",");
    }

    function selection(id: string, index: int): int {
        return Rows.selectionIndex(id, index, Array.from(root.facade).map(item => ({ id: item.id })));
    }

    function selectionOnNative(id: string, index: int): int {
        return Rows.selectionIndex(id, index, root.facade);
    }
}
)";

} // namespace

class ClipboardQmlTest : public QObject {
    Q_OBJECT

private slots:
    void nativeVariantListReachesDisplayRows();
};

void ClipboardQmlTest::nativeVariantListReachesDisplayRows() {
    QQmlEngine engine;
    NativeHistory service;

    QQmlComponent component(&engine);
    // The JS file is imported by relative path from its real directory.
    component.setData(harness, QUrl::fromLocalFile(QStringLiteral(CLIPBOARD_SERVICE_DIR "/harness.qml")));
    QVERIFY2(component.isReady(), qPrintable(component.errorString()));

    std::unique_ptr<QObject> root(component.createWithInitialProperties(
        { { QStringLiteral("service"), QVariant::fromValue(&service) } }));
    QVERIFY2(root, qPrintable(component.errorString()));

    service.setItems({ entry(QStringLiteral("a"), QStringLiteral("first")),
        entry(QStringLiteral("b"), QStringLiteral("MATCH one")),
        entry(QStringLiteral("c"), QStringLiteral("third")) });

    // Documents the boundary the fix exists for. It is informational only: if a
    // future Qt hands over a real Array, the assertions below still hold.
    bool isArray = true;
    QVERIFY(QMetaObject::invokeMethod(root.get(), "facadeIsArray", Q_RETURN_ARG(bool, isArray)));
    qInfo() << "Array.isArray(facade items) for a native QVariantList:" << isArray;

    QString ids;
    QVERIFY(QMetaObject::invokeMethod(root.get(), "ids", Q_RETURN_ARG(QString, ids), Q_ARG(QString, QString())));
    QCOMPARE(ids, QStringLiteral("a,b,c"));

    QVERIFY(QMetaObject::invokeMethod(root.get(), "ids", Q_RETURN_ARG(QString, ids), Q_ARG(QString, QStringLiteral("match"))));
    QCOMPARE(ids, QStringLiteral("b"));

    // Selection helpers accept the native list as well as the rows built from it.
    int index = -2;
    QVERIFY(QMetaObject::invokeMethod(root.get(), "selectionOnNative", Q_RETURN_ARG(int, index),
        Q_ARG(QString, QStringLiteral("c")), Q_ARG(int, 0)));
    QCOMPARE(index, 2);
    QVERIFY(QMetaObject::invokeMethod(root.get(), "selection", Q_RETURN_ARG(int, index),
        Q_ARG(QString, QStringLiteral("c")), Q_ARG(int, 0)));
    QCOMPARE(index, 2);

    // A later native update flows through the same chain.
    service.setItems({ entry(QStringLiteral("z"), QStringLiteral("newest")),
        entry(QStringLiteral("a"), QStringLiteral("first")) });
    QVERIFY(QMetaObject::invokeMethod(root.get(), "ids", Q_RETURN_ARG(QString, ids), Q_ARG(QString, QString())));
    QCOMPARE(ids, QStringLiteral("z,a"));

    // An empty native list is an empty history, not an error.
    service.setItems({});
    QVERIFY(QMetaObject::invokeMethod(root.get(), "ids", Q_RETURN_ARG(QString, ids), Q_ARG(QString, QString())));
    QCOMPARE(ids, QString());
    QVERIFY(QMetaObject::invokeMethod(root.get(), "selectionOnNative", Q_RETURN_ARG(int, index),
        Q_ARG(QString, QStringLiteral("a")), Q_ARG(int, 0)));
    QCOMPARE(index, -1);
}

QTEST_GUILESS_MAIN(ClipboardQmlTest)

#include "clipboardqml_test.moc"
