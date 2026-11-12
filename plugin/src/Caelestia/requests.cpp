#include "requests.hpp"

#include <chrono>
#include <limits>
#include <memory>

#include <qbytearray.h>
#include <qjsvalue.h>
#include <qjsvalueiterator.h>
#include <qloggingcategory.h>
#include <qnetworkaccessmanager.h>
#include <qnetworkcookiejar.h>
#include <qnetworkreply.h>
#include <qnetworkrequest.h>
#include <qpointer.h>
#include <qqmlengine.h>
#include <qtimer.h>
#include <qvariant.h>

namespace {

Q_LOGGING_CATEGORY(lcRequests, "caelestia.requests", QtInfoMsg)

} // namespace

namespace caelestia::shell {

using Qt::StringLiterals::operator""_s;
using Qt::StringLiterals::operator""_ba;

namespace {

struct RequestOptions {
    qint64 maxBytes = Requests::DefaultMaxResponseBytes;
    int deadlineMs = Requests::DefaultDeadlineMs;
    int inactivityTimeoutMs = Requests::DefaultInactivityTimeoutMs;
    int maxRedirects = Requests::DefaultMaxRedirects;
};

qint64 readPositiveInt64Option(const QJSValue& options, const QString& key, qint64 fallback) {
    if (!options.isObject() || !options.hasProperty(key))
        return fallback;
    const QJSValue value = options.property(key);
    if (!value.isNumber())
        return fallback;
    const double number = value.toNumber();
    if (number < 1.0 || number > static_cast<double>(std::numeric_limits<qint64>::max()))
        return fallback;
    return static_cast<qint64>(number);
}

int readNonNegativeIntOption(const QJSValue& options, const QString& key, int fallback, int minValue) {
    if (!options.isObject() || !options.hasProperty(key))
        return fallback;
    const QJSValue value = options.property(key);
    if (!value.isNumber())
        return fallback;
    const double number = value.toNumber();
    if (number < static_cast<double>(minValue) || number > static_cast<double>(std::numeric_limits<int>::max()))
        return fallback;
    return static_cast<int>(number);
}

RequestOptions parseRequestOptions(const QJSValue& options) {
    RequestOptions parsed;
    if (!options.isObject())
        return parsed;

    parsed.maxBytes = readPositiveInt64Option(options, u"maxBytes"_s, parsed.maxBytes);
    parsed.deadlineMs = readNonNegativeIntOption(options, u"deadlineMs"_s, parsed.deadlineMs, 1);
    parsed.inactivityTimeoutMs =
        readNonNegativeIntOption(options, u"inactivityTimeoutMs"_s, parsed.inactivityTimeoutMs, 1);
    parsed.maxRedirects = readNonNegativeIntOption(options, u"maxRedirects"_s, parsed.maxRedirects, 0);
    return parsed;
}

QVariantMap responseMetadata(const QNetworkReply* reply) {
    QVariantMap headers;

    for (const auto& [name, value] : reply->rawHeaderPairs()) {
        headers.insert(QString::fromLatin1(name).toLower(), QString::fromLatin1(value));
    }

    return {
        { u"statusCode"_s, reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() },
        { u"headers"_s, headers },
    };
}

struct RequestState {
    QPointer<const Requests> owner;
    QPointer<QNetworkReply> reply;
    QPointer<QTimer> deadlineTimer;
    QJSValue onSuccess;
    QJSValue onError;
    QByteArray body;
    qint64 maxBytes = Requests::DefaultMaxResponseBytes;
    bool settled = false;
    bool abortedByLimit = false;
};

void invokeError(const QPointer<const Requests>& owner, const QJSValue& onError, const QString& reason,
    const QVariantMap& rawMetadata) {
    if (onError.isCallable()) {
        QJSValue metadata;
        if (owner) {
            if (auto* engine = qjsEngine(owner.data()))
                metadata = engine->toScriptValue(rawMetadata);
        }
        onError.call({ reason, metadata });
    } else {
        qCWarning(lcRequests) << "get: request failed with error" << reason;
    }
}

// The owner dies with its QML engine. A callback after that would run script
// in an engine that is being torn down, so the request ends without one.
bool dropWithoutOwner(const std::shared_ptr<RequestState>& state) {
    if (state->owner)
        return false;
    state->settled = true;
    state->body.clear();
    if (state->deadlineTimer)
        state->deadlineTimer->stop();
    if (state->reply)
        state->reply->deleteLater();
    return true;
}

void settleSuccess(const std::shared_ptr<RequestState>& state) {
    if (state->settled || dropWithoutOwner(state))
        return;
    state->settled = true;

    if (state->deadlineTimer)
        state->deadlineTimer->stop();

    QJSValue metadata;
    if (state->owner && state->reply) {
        if (auto* engine = qjsEngine(state->owner.data()))
            metadata = engine->toScriptValue(responseMetadata(state->reply));
    }

    const QString text = QString::fromUtf8(state->body);
    state->body.clear();
    state->onSuccess.call({ text, metadata });

    if (state->reply)
        state->reply->deleteLater();
}

void settleError(const std::shared_ptr<RequestState>& state, const QString& reason) {
    if (state->settled || dropWithoutOwner(state))
        return;
    state->settled = true;

    if (state->deadlineTimer)
        state->deadlineTimer->stop();

    state->body.clear();
    const QVariantMap rawMetadata = state->reply ? responseMetadata(state->reply) : QVariantMap{};
    invokeError(state->owner, state->onError, reason, rawMetadata);

    if (state->reply)
        state->reply->deleteLater();
}

void abortWithLimit(const std::shared_ptr<RequestState>& state, const QString& reason) {
    if (state->settled || state->abortedByLimit)
        return;
    state->abortedByLimit = true;

    if (state->deadlineTimer)
        state->deadlineTimer->stop();

    // Deliver the terminal error once and abort the underlying reply so no extra
    // payload bytes are buffered. Any subsequent finished/destroyed signal sees
    // state->settled == true.
    settleError(state, reason);

    if (state->reply)
        state->reply->abort();
}

void consumeAvailableBytes(const std::shared_ptr<RequestState>& state) {
    if (state->settled || state->abortedByLimit || !state->reply)
        return;

    while (state->reply && state->reply->bytesAvailable() > 0) {
        const qint64 remaining = state->maxBytes - state->body.size();
        // Read up to remaining + 1 bytes so an oversized body trips immediately
        // without buffering the rest of the socket or decompressor output.
        const QByteArray chunk = state->reply->read(remaining + 1);
        if (chunk.isEmpty())
            break;
        if (chunk.size() > remaining) {
            abortWithLimit(state,
                u"Response body exceeded maximum size of %1 bytes"_s.arg(state->maxBytes));
            return;
        }
        state->body.append(chunk);
    }
}

} // namespace

Requests::Requests(QObject* parent)
    : QObject(parent)
    , m_manager(new QNetworkAccessManager(this)) {}

void Requests::get(const QUrl& url, const QJSValue& onSuccess, const QJSValue& onError, const QJSValue& headers,
    const QJSValue& options) const {
    if (!onSuccess.isCallable()) {
        qCWarning(lcRequests) << "get: onSuccess is not callable";
        return;
    }

    const RequestOptions opts = parseRequestOptions(options);

    QNetworkRequest request(url);
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setMaximumRedirectsAllowed(opts.maxRedirects);
    request.setRawHeader("Cache-Control"_ba, "no-cache, no-store"_ba);
    request.setRawHeader("Pragma"_ba, "no-cache"_ba);
    request.setRawHeader("Connection"_ba, "close"_ba);
    // Inactivity timeout: resets on network activity, bounded independently by
    // the total wall-clock deadline timer below.
    request.setTransferTimeout(std::chrono::milliseconds(opts.inactivityTimeoutMs));

    if (headers.isObject()) {
        QJSValueIterator it(headers);
        while (it.hasNext()) {
            it.next();
            request.setRawHeader(it.name().toUtf8(), it.value().toString().toUtf8());
        }
    }

    auto* reply = m_manager->get(request);
    auto state = std::make_shared<RequestState>();
    state->owner = this;
    state->reply = reply;
    state->onSuccess = onSuccess;
    state->onError = onError;
    state->maxBytes = opts.maxBytes;

    // Parent the timer to reply so it cannot outlive the reply.
    auto* deadlineTimer = new QTimer(reply);
    deadlineTimer->setSingleShot(true);
    state->deadlineTimer = deadlineTimer;

    QObject::connect(deadlineTimer, &QTimer::timeout, reply, [state, deadlineMs = opts.deadlineMs] {
        abortWithLimit(state, u"Request exceeded total deadline of %1 ms"_s.arg(deadlineMs));
    });
    deadlineTimer->start(opts.deadlineMs);

    QObject::connect(reply, &QNetworkReply::metaDataChanged, reply, [state] {
        if (state->settled || state->abortedByLimit || !state->reply)
            return;
        bool ok = false;
        const qint64 contentLength = state->reply->header(QNetworkRequest::ContentLengthHeader).toLongLong(&ok);
        if (ok && contentLength > state->maxBytes) {
            abortWithLimit(state,
                u"Response Content-Length (%1 bytes) exceeded maximum size of %2 bytes"_s
                    .arg(contentLength)
                    .arg(state->maxBytes));
        }
    });

    QObject::connect(reply, &QNetworkReply::downloadProgress, reply, [state](qint64 bytesReceived, qint64 bytesTotal) {
        if (state->settled || state->abortedByLimit)
            return;
        if (bytesTotal > state->maxBytes) {
            abortWithLimit(state,
                u"Response size (%1 bytes) exceeded maximum size of %2 bytes"_s
                    .arg(bytesTotal)
                    .arg(state->maxBytes));
            return;
        }
        if (bytesReceived > state->maxBytes) {
            abortWithLimit(state,
                u"Response body exceeded maximum size of %1 bytes"_s.arg(state->maxBytes));
        }
    });

    QObject::connect(reply, &QIODevice::readyRead, reply, [state] {
        consumeAvailableBytes(state);
    });

    QObject::connect(reply, &QNetworkReply::finished, reply, [state] {
        consumeAvailableBytes(state);
        if (state->settled) {
            if (state->reply)
                state->reply->deleteLater();
            return;
        }
        if (!state->reply) {
            settleError(state, u"Request destroyed before completion"_s);
            return;
        }
        if (state->reply->error() == QNetworkReply::NoError) {
            settleSuccess(state);
        } else {
            settleError(state, state->reply->errorString());
        }
    });

    // Destroying the owner cancels the request without a callback.
    QObject::connect(this, &QObject::destroyed, reply, [state] {
        if (state->settled)
            return;
        state->settled = true;
        state->body.clear();
        if (state->reply)
            state->reply->abort();
    });
}

void Requests::resetCookies() const {
    m_manager->setCookieJar(new QNetworkCookieJar(m_manager));
}

} // namespace caelestia::shell
