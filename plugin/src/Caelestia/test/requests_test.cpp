#include "requests.hpp"

#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>

#include <qbytearray.h>
#include <qcoreapplication.h>
#include <qdir.h>
#include <qfile.h>
#include <qhostaddress.h>
#include <qjsengine.h>
#include <qjsvalue.h>
#include <qqmlengine.h>
#include <qtcpserver.h>
#include <qtcpsocket.h>
#include <qtest.h>
#include <qtimer.h>
#include <qurl.h>
#include <quuid.h>
#include <zlib.h>

namespace {

using caelestia::shell::Requests;

QByteArray gzipCompress(const QByteArray& raw) {
    z_stream stream{};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        return {};

    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(raw.constData()));
    stream.avail_in = static_cast<uInt>(raw.size());

    QByteArray out;
    char buffer[4096];
    int status = Z_OK;
    do {
        stream.next_out = reinterpret_cast<Bytef*>(buffer);
        stream.avail_out = sizeof(buffer);
        status = deflate(&stream, Z_FINISH);
        const qsizetype have = static_cast<qsizetype>(sizeof(buffer) - stream.avail_out);
        if (have > 0)
            out.append(buffer, have);
    } while (status == Z_OK);

    deflateEnd(&stream);
    if (status != Z_STREAM_END)
        return {};
    return out;
}

class LocalHttpServer : public QObject {
    Q_OBJECT

public:
    using Handler = std::function<void(QTcpSocket* socket, const QByteArray& request)>;

    explicit LocalHttpServer(Handler handler, QObject* parent = nullptr)
        : QObject(parent)
        , m_handler(std::move(handler)) {
        QObject::connect(&m_server, &QTcpServer::newConnection, this, [this] {
            while (QTcpSocket* socket = m_server.nextPendingConnection()) {
                auto buffer = std::make_shared<QByteArray>();
                auto handled = std::make_shared<bool>(false);
                QObject::connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
                QObject::connect(socket, &QTcpSocket::readyRead, socket, [this, socket, buffer, handled] {
                    if (*handled)
                        return;
                    buffer->append(socket->readAll());
                    if (buffer->contains("\r\n\r\n")) {
                        *handled = true;
                        m_handler(socket, *buffer);
                    }
                });
            }
        });
    }

    bool listen() { return m_server.listen(QHostAddress::LocalHost, 0); }

    [[nodiscard]] QUrl url(const QString& path = QStringLiteral("/")) const {
        return QUrl(QStringLiteral("http://127.0.0.1:%1%2").arg(m_server.serverPort()).arg(path));
    }

private:
    QTcpServer m_server;
    Handler m_handler;
};

struct CallbackRecorder {
    int successCount = 0;
    int errorCount = 0;
    QString body;
    QString error;
    int statusCode = 0;
    QVariantMap headers;

    [[nodiscard]] int totalCalls() const { return successCount + errorCount; }

    static QString install(QJSEngine&) {
        return QStringLiteral(
            "(() => {"
            "  const state = { success: 0, error: 0, body: '', errText: '', statusCode: 0, headers: {} };"
            "  return {"
            "    state,"
            "    onSuccess: (text, meta) => {"
            "      state.success++;"
            "      state.body = text;"
            "      state.statusCode = meta?.statusCode ?? 0;"
            "      state.headers = meta?.headers ?? {};"
            "    },"
            "    onError: (err, meta) => {"
            "      state.error++;"
            "      state.errText = err;"
            "      state.statusCode = meta?.statusCode ?? 0;"
            "      state.headers = meta?.headers ?? {};"
            "    }"
            "  };"
            "})()");
    }
};

CallbackRecorder readRecorder(const QJSValue& handle) {
    const QJSValue state = handle.property(QStringLiteral("state"));
    CallbackRecorder rec;
    rec.successCount = state.property(QStringLiteral("success")).toInt();
    rec.errorCount = state.property(QStringLiteral("error")).toInt();
    rec.body = state.property(QStringLiteral("body")).toString();
    rec.error = state.property(QStringLiteral("errText")).toString();
    rec.statusCode = state.property(QStringLiteral("statusCode")).toInt();
    rec.headers = state.property(QStringLiteral("headers")).toVariant().toMap();
    return rec;
}

QJSValue makeOptions(QJSEngine& engine, qint64 maxBytes, int deadlineMs, int inactivityMs, int maxRedirects) {
    QJSValue opts = engine.newObject();
    opts.setProperty(QStringLiteral("maxBytes"), static_cast<double>(maxBytes));
    opts.setProperty(QStringLiteral("deadlineMs"), deadlineMs);
    opts.setProperty(QStringLiteral("inactivityTimeoutMs"), inactivityMs);
    opts.setProperty(QStringLiteral("maxRedirects"), maxRedirects);
    return opts;
}

} // namespace

class RequestsTest : public QObject {
    Q_OBJECT

public:
    explicit RequestsTest(QObject* parent = nullptr)
        : QObject(parent) {}

private slots:
    void normalResponseDeliversSingleSuccess() {
        QQmlEngine engine;
        Requests requests;
        QJSValue jsRequests = engine.newQObject(&requests);
        QJSEngine::setObjectOwnership(&requests, QJSEngine::CppOwnership);
        Q_UNUSED(jsRequests);
        const QByteArray payload("{\"ok\":true,\"city\":\"Test\"}");
        LocalHttpServer server([payload](QTcpSocket* socket, const QByteArray&) {
            const QByteArray response = "HTTP/1.1 200 OK\r\n"
                                        "Content-Type: application/json\r\n"
                                        "X-Custom: hello\r\n"
                                        "Content-Length: "
                + QByteArray::number(payload.size()) + "\r\nConnection: close\r\n\r\n" + payload;
            socket->write(response);
            socket->disconnectFromHost();
        });
        QVERIFY(server.listen());

        const QJSValue handle = engine.evaluate(CallbackRecorder::install(engine));
        requests.get(server.url(QStringLiteral("/ok")), handle.property(QStringLiteral("onSuccess")),
            handle.property(QStringLiteral("onError")));

        QTRY_COMPARE_WITH_TIMEOUT(readRecorder(handle).totalCalls(), 1, 5000);
        QTest::qWait(50);

        const CallbackRecorder rec = readRecorder(handle);
        QCOMPARE(rec.successCount, 1);
        QCOMPARE(rec.errorCount, 0);
        QCOMPARE(rec.body, QString::fromUtf8(payload));
        QCOMPARE(rec.statusCode, 200);
        QCOMPARE(rec.headers.value(QStringLiteral("x-custom")).toString(), QStringLiteral("hello"));
    }

    void oversizedBodyAbortsWithSingleError() {
        QQmlEngine engine;
        Requests requests;
        const QByteArray payload(2048, 'X');
        LocalHttpServer server([payload](QTcpSocket* socket, const QByteArray&) {
            // Omit Content-Length to ensure streaming readyRead/downloadProgress
            // enforcement aborts even when length is not declared up front.
            socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
            socket->write(payload);
            socket->disconnectFromHost();
        });
        QVERIFY(server.listen());

        const QJSValue handle = engine.evaluate(CallbackRecorder::install(engine));
        requests.get(server.url(QStringLiteral("/big")), handle.property(QStringLiteral("onSuccess")),
            handle.property(QStringLiteral("onError")), QJSValue(), makeOptions(engine, 512, 5000, 5000, 5));

        QTRY_COMPARE_WITH_TIMEOUT(readRecorder(handle).totalCalls(), 1, 5000);
        QTest::qWait(100);

        const CallbackRecorder rec = readRecorder(handle);
        QCOMPARE(rec.successCount, 0);
        QCOMPARE(rec.errorCount, 1);
        QVERIFY(rec.error.contains(QStringLiteral("exceeded maximum size")));
    }

    void slowTrickleHitsWallClockDeadline() {
        QQmlEngine engine;
        Requests requests;
        LocalHttpServer server([](QTcpSocket* socket, const QByteArray&) {
            socket->write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n");
            socket->flush();
            auto* timer = new QTimer(socket);
            timer->setInterval(40);
            QObject::connect(timer, &QTimer::timeout, socket, [socket] {
                if (socket->state() == QAbstractSocket::ConnectedState) {
                    socket->write("a");
                    socket->flush();
                }
            });
            timer->start();
        });
        QVERIFY(server.listen());

        const QJSValue handle = engine.evaluate(CallbackRecorder::install(engine));
        // Inactivity timeout (1000ms) is longer than the trickle interval (40ms),
        // so only the total deadline (250ms) stops the stream.
        requests.get(server.url(QStringLiteral("/trickle")), handle.property(QStringLiteral("onSuccess")),
            handle.property(QStringLiteral("onError")), QJSValue(), makeOptions(engine, 1024 * 1024, 250, 1000, 5));

        QTRY_COMPARE_WITH_TIMEOUT(readRecorder(handle).totalCalls(), 1, 5000);
        QTest::qWait(100);

        const CallbackRecorder rec = readRecorder(handle);
        QCOMPARE(rec.successCount, 0);
        QCOMPARE(rec.errorCount, 1);
        QVERIFY(rec.error.contains(QStringLiteral("exceeded total deadline")));
    }

    void gzipBombExpandsPastDecompressedCapAndAborts() {
        QQmlEngine engine;
        Requests requests;
        const QByteArray raw(16384, 'Z');
        const QByteArray compressed = gzipCompress(raw);
        QVERIFY(!compressed.isEmpty());
        QVERIFY(compressed.size() < 256);

        LocalHttpServer server([compressed](QTcpSocket* socket, const QByteArray&) {
            const QByteArray response = "HTTP/1.1 200 OK\r\n"
                                        "Content-Encoding: gzip\r\n"
                                        "Content-Length: "
                + QByteArray::number(compressed.size()) + "\r\nConnection: close\r\n\r\n" + compressed;
            socket->write(response);
            socket->disconnectFromHost();
        });
        QVERIFY(server.listen());

        const QJSValue handle = engine.evaluate(CallbackRecorder::install(engine));
        // Cap (1024 bytes) is larger than the compressed wire payload (< 256 bytes)
        // so Content-Length passes, and only the decompressed byte check trips.
        requests.get(server.url(QStringLiteral("/gzip")), handle.property(QStringLiteral("onSuccess")),
            handle.property(QStringLiteral("onError")), QJSValue(), makeOptions(engine, 1024, 5000, 5000, 5));

        QTRY_COMPARE_WITH_TIMEOUT(readRecorder(handle).totalCalls(), 1, 5000);
        QTest::qWait(100);

        const CallbackRecorder rec = readRecorder(handle);
        QCOMPARE(rec.successCount, 0);
        QCOMPARE(rec.errorCount, 1);
        QVERIFY(rec.error.contains(QStringLiteral("exceeded maximum size")));
    }

    void redirectChainWithinLimitSucceedsAndPastLimitFailsOnce() {
        QQmlEngine engine;
        Requests requests;
        int hops = 0;
        LocalHttpServer server([&hops](QTcpSocket* socket, const QByteArray& request) {
            if (request.startsWith("GET /final ")) {
                const QByteArray body("redirect-ok");
                const QByteArray response = "HTTP/1.1 200 OK\r\nContent-Length: "
                    + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
                socket->write(response);
                socket->disconnectFromHost();
                return;
            }
            hops++;
            const QByteArray next = request.startsWith("GET /good ") ? "/final" : ("/step-" + QByteArray::number(hops));
            const QByteArray response = "HTTP/1.1 302 Found\r\nLocation: " + next
                + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            socket->write(response);
            socket->disconnectFromHost();
        });
        QVERIFY(server.listen());

        const QJSValue okHandle = engine.evaluate(CallbackRecorder::install(engine));
        requests.get(server.url(QStringLiteral("/good")), okHandle.property(QStringLiteral("onSuccess")),
            okHandle.property(QStringLiteral("onError")), QJSValue(), makeOptions(engine, 1024 * 1024, 5000, 5000, 2));
        QTRY_COMPARE_WITH_TIMEOUT(readRecorder(okHandle).totalCalls(), 1, 5000);
        const CallbackRecorder okRec = readRecorder(okHandle);
        QCOMPARE(okRec.successCount, 1);
        QCOMPARE(okRec.errorCount, 0);
        QCOMPARE(okRec.body, QStringLiteral("redirect-ok"));

        hops = 0;
        const QJSValue failHandle = engine.evaluate(CallbackRecorder::install(engine));
        requests.get(server.url(QStringLiteral("/start")), failHandle.property(QStringLiteral("onSuccess")),
            failHandle.property(QStringLiteral("onError")), QJSValue(), makeOptions(engine, 1024 * 1024, 5000, 5000, 2));

        QTRY_COMPARE_WITH_TIMEOUT(readRecorder(failHandle).totalCalls(), 1, 5000);
        QTest::qWait(100);

        const CallbackRecorder failRec = readRecorder(failHandle);
        QCOMPARE(failRec.successCount, 0);
        QCOMPARE(failRec.errorCount, 1);
        QVERIFY(hops <= 3);
    }

    void destructionMidRequestCancelsWithoutCallback() {
        QQmlEngine engine;
        auto requests = std::make_unique<Requests>();
        bool connected = false;
        LocalHttpServer server([&connected](QTcpSocket*, const QByteArray&) {
            // Keep socket open without sending a response body.
            connected = true;
        });
        QVERIFY(server.listen());

        const QJSValue handle = engine.evaluate(CallbackRecorder::install(engine));
        requests->get(server.url(QStringLiteral("/hang")), handle.property(QStringLiteral("onSuccess")),
            handle.property(QStringLiteral("onError")), QJSValue(), makeOptions(engine, 1024 * 1024, 5000, 5000, 5));

        QTRY_VERIFY_WITH_TIMEOUT(connected, 5000);
        requests.reset();

        // The owner is gone, so no script callback may run.
        QTest::qWait(300);
        QCOMPARE(readRecorder(handle).totalCalls(), 0);
    }
};

// Qt Test's own stdout logger prints nothing when stdout is redirected, so log to
// a temporary file and echo failure lines when a test fails.
int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    RequestsTest test;

    const QString logPath = QDir::temp().filePath(QStringLiteral("requests-tests-%1.log")
                                                     .arg(QUuid::createUuid().toString(QUuid::Id128)));
    QStringList arguments = app.arguments();
    arguments << QStringLiteral("-o") << (logPath + QStringLiteral(",txt"));

    const int result = QTest::qExec(&test, arguments);
    if (result != 0) {
        QFile log(logPath);
        if (log.open(QIODevice::ReadOnly)) {
            const QByteArray text = log.readAll();
            std::fwrite(text.constData(), 1, static_cast<size_t>(text.size()), stdout);
            std::fflush(stdout);
        }
    }
    QFile::remove(logPath);
    return result;
}

#include "requests_test.moc"
