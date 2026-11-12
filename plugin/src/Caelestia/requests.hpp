#pragma once

#include <qnetworkaccessmanager.h>
#include <qobject.h>
#include <qqmlengine.h>

namespace caelestia::shell {

class Requests : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    static constexpr qint64 DefaultMaxResponseBytes = 1024 * 1024;
    static constexpr int DefaultDeadlineMs = 30000;
    static constexpr int DefaultInactivityTimeoutMs = 15000;
    static constexpr int DefaultMaxRedirects = 5;

    explicit Requests(QObject* parent = nullptr);

    Q_INVOKABLE void get(const QUrl& url, const QJSValue& onSuccess, const QJSValue& onError = QJSValue(),
        const QJSValue& headers = QJSValue(), const QJSValue& options = QJSValue()) const;
    Q_INVOKABLE void resetCookies() const;

private:
    QNetworkAccessManager* m_manager;
};

} // namespace caelestia::shell
