#include "rootnode.hpp"

#include <qcoreapplication.h>
#include <qjsonobject.h>

namespace caelestia::shell::settings {

RootNode::RootNode(bool watch, const QString& path, RootNode* fallback, QObject* parent)
    : ObjectNode(fallback, parent)
    , m_file(new SettingsFile(watch, path, this)) {
    QObject::connect(batcher(), &ChangeBatcher::dirtied, this, &RootNode::saveToFile);
    if (const auto* app = QCoreApplication::instance())
        QObject::connect(app, &QCoreApplication::aboutToQuit, this, &RootNode::flushPending);
    QObject::connect(m_file, &SettingsFile::changed, this, &RootNode::reloadFromFile);
    QObject::connect(m_file, &SettingsFile::readFailed, this, [this](const QString& error) {
        emit treeLoadFailed(this, error);
    });
    QObject::connect(m_file, &SettingsFile::writeFailed, this, [this](const QString& error) {
        emit treeSaveFailed(this, error);
    });
}

RootNode::~RootNode() {
    // Concrete derived classes have already been destroyed here, so schema()
    // is no longer callable; only flush any already-serialized payload.
    m_file->flush();
}

void RootNode::load() {
    if (m_file->load() != SettingsFile::LoadResult::Changed)
        reloadFromFile();
}

QList<Diagnostic> RootNode::diagnostics() const {
    return m_diagnostics;
}

void RootNode::reloadFromFile() {
    const auto oldDiagnostics = m_diagnostics;
    m_diagnostics.clear();

    const auto data = m_file->read();
    syncJson(data ? data.value() : QJsonObject(), m_diagnostics);

    if (m_diagnostics != oldDiagnostics)
        emit diagnosticsChanged();

    emit treeLoaded(this);
}

void RootNode::saveToFile() {
    m_file->write(toJson());
}

void RootNode::flushPending() {
    // Queued changes must reach disk on quit or destruction, bypassing debounce
    batcher()->flush();
    m_file->flush();
}

} // namespace caelestia::shell::settings
