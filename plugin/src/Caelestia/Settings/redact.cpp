#include "redact.hpp"

#include <qbytearray.h>
#include <qcryptographichash.h>
#include <qrandom.h>

namespace caelestia::shell::settings {

namespace {

const QByteArray& processSalt() {
    static const auto salt = [] {
        auto bytes = QByteArray(16, '\0');
        auto* random = QRandomGenerator::system();
        for (auto& byte : bytes)
            byte = static_cast<char>(random->bounded(256));
        return bytes;
    }();
    return salt;
}

} // namespace

QString logId(const QString& value) {
    if (value.isEmpty())
        return QStringLiteral("<empty>");
    auto digest = QCryptographicHash::hash(processSalt() + value.toUtf8(), QCryptographicHash::Sha256);
    return QStringLiteral("redacted:") + QString::fromLatin1(digest.toHex().left(12));
}

} // namespace caelestia::shell::settings
