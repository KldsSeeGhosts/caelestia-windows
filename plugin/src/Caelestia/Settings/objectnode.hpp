#pragma once

#include <qjsonobject.h>
#include <qobject.h>
#include <qset.h>

#include "node.hpp"

namespace caelestia::shell::settings {

class CAELESTIA_SETTINGS_API ObjectNode : public Node {
    Q_OBJECT

public:
    explicit ObjectNode(ObjectNode* fallback, QObject* parent = nullptr, bool globalOnly = false);

    Q_INVOKABLE void resetOption(const QString& key);
    [[nodiscard]] Q_INVOKABLE caelestia::shell::settings::Descriptor descriptorFor(const QString& key) const;

    [[nodiscard]] QJsonValue toJson(bool sparse = true) const override;
    bool syncJson(const QJsonValue& json, QList<Diagnostic>& diagnostics) override;

protected:
    // Called while the file write scope is active after any key in this object
    // produced a diagnostic. Nodes whose fields are one executable unit can
    // disable themselves rather than run with quarantined/defaulted fields.
    virtual void onJsonDecoded(bool valid);

private:
    void quarantineKey(const QString& key, const QJsonValue& value);

    QSet<QString> loadFromJson(const QJsonObject& json, QList<Diagnostic>& diagnostics);
    void resetUnvisited(const QSet<QString>& visited);
};

} // namespace caelestia::shell::settings
