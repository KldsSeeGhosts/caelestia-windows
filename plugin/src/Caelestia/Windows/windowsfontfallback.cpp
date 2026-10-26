#include "windowsfontfallback.hpp"

namespace caelestia::shell::windows {

QFont WindowsFontFallback::workspaceFont(QFont font, const QString& primary) const {
    // Application fonts are not reliably found by Windows system fallback.
    // QML 6.11 does not expose QFont::families. Keep all other font attributes
    // and the configured primary, then explicitly try the bundled Nerd font.
    font.setFamilies({primary, QStringLiteral("Symbols Nerd Font Mono")});
    return font;
}

} // namespace caelestia::shell::windows
