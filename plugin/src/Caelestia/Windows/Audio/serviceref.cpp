#include "serviceref.hpp"

namespace caelestia::shell::windows::audio {

ServiceRef::ServiceRef(QObject* parent)
    : QObject(parent) {}

ServiceRef::~ServiceRef() {
    setService(nullptr);
}

::caelestia::shell::services::Service* ServiceRef::service() const {
    return m_service;
}

void ServiceRef::setService(::caelestia::shell::services::Service* service) {
    if (m_service == service) {
        return;
    }

    if (m_service) {
        m_service->unref(this);
    }

    m_service = service;
    emit serviceChanged();

    if (m_service) {
        m_service->ref(this);
    }
}

} // namespace caelestia::shell::windows::audio
