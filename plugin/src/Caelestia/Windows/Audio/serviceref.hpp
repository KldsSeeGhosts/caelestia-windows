#pragma once

#include <qpointer.h>
#include <qqmlintegration.h>

#include "../Services/service.hpp"

namespace caelestia::shell::windows::audio {

// Windows copy of Caelestia's ServiceRef. The upstream header is compiled into
// the Windows module too, but Qt's moc emits its property type without a global
// qualifier and clang-cl rejects that inside the specialization body. The
// behaviour is identical: ref() on construction and assignment, unref() on
// destruction and replacement.
class ServiceRef : public QObject {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(::caelestia::shell::services::Service* service READ service WRITE setService NOTIFY serviceChanged)

public:
    explicit ServiceRef(QObject* parent = nullptr);
    ~ServiceRef() override;

    [[nodiscard]] ::caelestia::shell::services::Service* service() const;
    void setService(::caelestia::shell::services::Service* service);

signals:
    void serviceChanged();

private:
    QPointer<::caelestia::shell::services::Service> m_service;
};

} // namespace caelestia::shell::windows::audio
