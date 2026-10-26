#include "windowsfontfallback.hpp"

#include <qfontdatabase.h>

namespace caelestia::shell::windows {

WindowsFontFallback::WindowsFontFallback(QObject* parent)
    : QObject(parent) {
    // Application fonts are not reliably found by Windows system fallback.
    // Nerd private-use glyphs have Script_Common in both BMP and plane 15.
    // Qt's explicit process-local fallback keeps each text's primary font.
    QFontDatabase::addApplicationFallbackFontFamily(
        QChar::Script_Common, QStringLiteral("Symbols Nerd Font Mono"));
}

} // namespace caelestia::shell::windows
