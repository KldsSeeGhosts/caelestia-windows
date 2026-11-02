#include "rootnodes.hpp"

#include "settings/redact.hpp"

namespace caelestia::shell::state {

using Qt::StringLiterals::operator""_s;

namespace {

QString nameFor(const QString& key) {
    return key.isEmpty() ? u"global"_s : settings::logId(key);
}

struct Handler {
    static void loaded(settings::RootNode* layer, const QString& screen) {
        const auto name = nameFor(screen);
        qCDebug(lcState) << "Loaded state for" << name << "with" << layer->diagnostics().count() << "issues";
    }

    static void loadFailed(const QString& error, const QString& screen) {
        const auto name = nameFor(screen);
        qCWarning(lcState) << "Failed to load state for" << name << ':' << error;
    }

    static void saveFailed(const QString& error, const QString& screen) {
        const auto name = nameFor(screen);
        qCWarning(lcState) << "Failed to save state for" << name << ':' << error;
    }
};

} // namespace

PStateRoot::PStateRoot(const QString& path, PStateRoot* fallback, QObject* parent)
    : RootNode(false, path, fallback, parent) {}

PStateRoot::~PStateRoot() {
    flushPending();
}

RStateRoot::RStateRoot(const QString& path, RStateRoot* fallback, QObject* parent)
    : RootNode(false, path, fallback, parent) {}

RStateRoot::~RStateRoot() {
    flushPending();
}

SETTINGS_SINGLETON_IMPL(PersistentState, PStateRoot, stateDir(), monitorStateDir(), u"state.json"_s, Handler)
SETTINGS_SINGLETON_IMPL(RuntimeState, RStateRoot, runtimeDir(), monitorRuntimeDir(), u"state.json"_s, Handler)

} // namespace caelestia::shell::state
