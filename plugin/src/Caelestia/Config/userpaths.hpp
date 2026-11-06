#pragma once

#include <qstandardpaths.h>
#include <qstring.h>

#include "util/export.hpp"

#include "settings/objectnode.hpp"
#include "common.hpp"

namespace caelestia::shell::config {

using Qt::StringLiterals::operator""_s;

class CAELESTIA_CONFIG_API UserPaths : public settings::ObjectNode {
    CONFIG_NODE(UserPaths, settings::ObjectNode)

#ifdef Q_OS_WIN
    // The Windows Paths adapter resolves the Pictures Known Folder, which may
    // be redirected. Keep the default empty so paths.wallpaperDir only carries
    // a path the user explicitly configured.
    CONFIG_GLOBAL_PROPERTY(QString, wallpaperDir, {})
#else
    CONFIG_GLOBAL_PROPERTY(
        QString, wallpaperDir, QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) + u"/Wallpapers"_s)
#endif
    CONFIG_GLOBAL_PROPERTY(
        QString, lyricsDir, QStandardPaths::writableLocation(QStandardPaths::MusicLocation) + u"/Lyrics/"_s)
    CONFIG_PROPERTY(QString, sessionGif, u"root:/assets/kurukuru.gif"_s)
    CONFIG_PROPERTY(QString, mediaGif, u"root:/assets/bongocat.gif"_s)
    CONFIG_PROPERTY(QString, noNotifsPic, u"root:/assets/dino.png"_s)
    CONFIG_PROPERTY(QString, lockNoNotifsPic, u"root:/assets/dino.png"_s)
};

} // namespace caelestia::shell::config
