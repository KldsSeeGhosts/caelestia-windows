#pragma once

#include <qstring.h>
#include <qstringlist.h>
#include <qvariantlist.h>

#include "util/export.hpp"

#include "settings/objectnode.hpp"
#include "util/i18n.hpp"
#include "common.hpp"

namespace caelestia::shell::config {

using Qt::StringLiterals::operator""_s;
using settings::vmap;
using util::i18n::mark;
using util::i18n::markCtx;

class CAELESTIA_CONFIG_API LauncherUseFuzzy : public settings::ObjectNode {
    CONFIG_NODE(LauncherUseFuzzy, settings::ObjectNode)

    CONFIG_PROPERTY(bool, apps, false)
    CONFIG_PROPERTY(bool, actions, false)
    CONFIG_PROPERTY(bool, schemes, false)
    CONFIG_PROPERTY(bool, variants, false)
    CONFIG_PROPERTY(bool, wallpapers, false)
};

class CAELESTIA_CONFIG_API LauncherAction : public settings::ObjectNode {
    CONFIG_NODE(LauncherAction, settings::ObjectNode)

    CONFIG_PROPERTY(bool, enabled, true)
    CONFIG_PROPERTY(QString, name, {})
    CONFIG_PROPERTY(QString, icon, {})
    CONFIG_PROPERTY(QString, description, {})
    CONFIG_PROPERTY(QStringList, command, {})
#ifdef Q_OS_WIN
    CONFIG_PROPERTY(QString, verb, {})
    CONFIG_PROPERTY(QString, target, {})
    CONFIG_PROPERTY(QString, aumid, {})
    CONFIG_PROPERTY(QString, uri, {})
    CONFIG_PROPERTY(QStringList, args, {})
    CONFIG_PROPERTY(QString, workingDir, {})
#endif
    CONFIG_PROPERTY(bool, dangerous, false)

    Q_PROPERTY(bool decodeValid READ decodeValid NOTIFY decodeValidChanged)

public:
    [[nodiscard]] bool decodeValid() const { return m_decodeValid; }

signals:
    void decodeValidChanged();

protected:
    // Launcher shell actions execute as one unit. If any supplied field is
    // malformed, the action must not run with the bad field silently reset.
    void onJsonDecoded(bool valid) override {
        if (m_decodeValid == valid)
            return;
        m_decodeValid = valid;
        emit decodeValidChanged();
    }

private:
    bool m_decodeValid = true;
};
CONFIG_LIST_TYPE(LauncherAction, LauncherActionList)

class CAELESTIA_CONFIG_API LauncherConfig : public settings::ObjectNode {
    CONFIG_NODE(LauncherConfig, settings::ObjectNode)

    CONFIG_PROPERTY(bool, enabled, true)
    CONFIG_PROPERTY(bool, showOnHover, false)
    CONFIG_PROPERTY(int, maxShown, 7)
    CONFIG_PROPERTY(int, maxWallpapers, 9)
    CONFIG_GLOBAL_PROPERTY(QString, specialPrefix, u"@"_s)
    CONFIG_GLOBAL_PROPERTY(QString, actionPrefix, u">"_s)
    CONFIG_GLOBAL_PROPERTY(bool, enableDangerousActions, false)
    CONFIG_PROPERTY(int, dragThreshold, 50)
    CONFIG_GLOBAL_PROPERTY(bool, vimKeybinds, false)
    CONFIG_GLOBAL_PROPERTY(QStringList, favouriteApps, {})
    CONFIG_GLOBAL_PROPERTY(QStringList, hiddenApps, {})
    CONFIG_GLOBAL_SUBOBJECT(LauncherUseFuzzy, useFuzzy)
#ifdef Q_OS_WIN
    CONFIG_GLOBAL_LIST(LauncherActionList, actions,
        DEFAULT_ARG({
            vmap({
                { u"name"_s, markCtx(u"Calculator"_s, u"launcher action"_s) },
                { u"icon"_s, u"calculate"_s },
                { u"description"_s, mark(u"Arithmetic and functions"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"calc"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Settings"_s, u"launcher action"_s) },
                { u"icon"_s, u"settings"_s },
                { u"description"_s, mark(u"Open Caelestia settings"_s) },
                { u"command"_s, QStringList{ u"settings"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Screenshot"_s, u"launcher action"_s) },
                { u"icon"_s, u"screenshot_region"_s },
                { u"description"_s, mark(u"Capture an area or window"_s) },
                { u"command"_s, QStringList{ u"screenshot"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Screenshot history"_s, u"launcher action"_s) },
                { u"icon"_s, u"history"_s },
                { u"description"_s, mark(u"Edit and export recent screenshots"_s) },
                { u"command"_s, QStringList{ u"screenshotHistory"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Record screen"_s, u"launcher action"_s) },
                { u"icon"_s, u"screen_record"_s },
                { u"description"_s, mark(u"Record the screen"_s) },
                { u"command"_s, QStringList{ u"record"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Wallpaper"_s, u"launcher action"_s) },
                { u"icon"_s, u"wallpaper"_s },
                { u"description"_s, mark(u"Browse wallpaper folder"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"wallpaper"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Choose wallpaper file"_s, u"launcher action"_s) },
                { u"icon"_s, u"image"_s },
                { u"description"_s, mark(u"Open the Windows image picker"_s) },
                { u"command"_s, QStringList{ u"chooseWallpaper"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Scheme"_s, u"launcher action"_s) },
                { u"icon"_s, u"palette"_s },
                { u"description"_s, mark(u"Change the current colour scheme"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"scheme"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Variant"_s, u"launcher action"_s) },
                { u"icon"_s, u"colors"_s },
                { u"description"_s, mark(u"Change the current scheme variant"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"variant"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Light"_s, u"launcher action"_s) },
                { u"icon"_s, u"light_mode"_s },
                { u"description"_s, mark(u"Change the scheme to light mode"_s) },
                { u"command"_s, QStringList{ u"setMode"_s, u"light"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Dark"_s, u"launcher action"_s) },
                { u"icon"_s, u"dark_mode"_s },
                { u"description"_s, mark(u"Change the scheme to dark mode"_s) },
                { u"command"_s, QStringList{ u"setMode"_s, u"dark"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Shutdown"_s, u"launcher action"_s) },
                { u"icon"_s, u"power_settings_new"_s },
                { u"description"_s, mark(u"Shutdown the system"_s) },
                { u"command"_s, QStringList{ u"shutdown"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Reboot"_s, u"launcher action"_s) },
                { u"icon"_s, u"cached"_s },
                { u"description"_s, mark(u"Reboot the system"_s) },
                { u"command"_s, QStringList{ u"reboot"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Hibernate"_s, u"launcher action"_s) },
                { u"icon"_s, u"bedtime"_s },
                { u"description"_s, mark(u"Hibernate the system"_s) },
                { u"command"_s, QStringList{ u"hibernate"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Reboot to firmware"_s, u"launcher action"_s) },
                { u"icon"_s, u"settings_applications"_s },
                { u"description"_s, mark(u"Reboot into the system firmware interface"_s) },
                { u"command"_s, QStringList{ u"firmware"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Logout"_s, u"launcher action"_s) },
                { u"icon"_s, u"exit_to_app"_s },
                { u"description"_s, mark(u"Log out of the current session"_s) },
                { u"command"_s, QStringList{ u"logout"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Lock"_s, u"launcher action"_s) },
                { u"icon"_s, u"lock"_s },
                { u"description"_s, mark(u"Lock the current session"_s) },
                { u"command"_s, QStringList{ u"lock"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Sleep"_s, u"launcher action"_s) },
                { u"icon"_s, u"bedtime"_s },
                { u"description"_s, mark(u"Suspend the system"_s) },
                { u"command"_s, QStringList{ u"suspend"_s } },
            }),
        }))
#else
    CONFIG_GLOBAL_LIST(LauncherActionList, actions,
        DEFAULT_ARG({
            vmap({
                { u"name"_s, markCtx(u"Calculator"_s, u"launcher action"_s) },
                { u"icon"_s, u"calculate"_s },
                { u"description"_s, mark(u"Do simple maths equations (powered by Qalc)"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"calc"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Scheme"_s, u"launcher action"_s) },
                { u"icon"_s, u"palette"_s },
                { u"description"_s, mark(u"Change the current colour scheme"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"scheme"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Wallpaper"_s, u"launcher action"_s) },
                { u"icon"_s, u"image"_s },
                { u"description"_s, mark(u"Change the current wallpaper"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"wallpaper"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Variant"_s, u"launcher action"_s) },
                { u"icon"_s, u"colors"_s },
                { u"description"_s, mark(u"Change the current scheme variant"_s) },
                { u"command"_s, QStringList{ u"autocomplete"_s, u"variant"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Random"_s, u"launcher action"_s) },
                { u"icon"_s, u"casino"_s },
                { u"description"_s, mark(u"Switch to a random wallpaper"_s) },
                { u"command"_s, QStringList{ u"caelestia"_s, u"wallpaper"_s, u"-r"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Light"_s, u"launcher action"_s) },
                { u"icon"_s, u"light_mode"_s },
                { u"description"_s, mark(u"Change the scheme to light mode"_s) },
                { u"command"_s, QStringList{ u"setMode"_s, u"light"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Dark"_s, u"launcher action"_s) },
                { u"icon"_s, u"dark_mode"_s },
                { u"description"_s, mark(u"Change the scheme to dark mode"_s) },
                { u"command"_s, QStringList{ u"setMode"_s, u"dark"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Shutdown"_s, u"launcher action"_s) },
                { u"icon"_s, u"power_settings_new"_s },
                { u"description"_s, mark(u"Shutdown the system"_s) },
                { u"command"_s, QStringList{ u"poweroff"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Reboot"_s, u"launcher action"_s) },
                { u"icon"_s, u"cached"_s },
                { u"description"_s, mark(u"Reboot the system"_s) },
                { u"command"_s, QStringList{ u"reboot"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Logout"_s, u"launcher action"_s) },
                { u"icon"_s, u"exit_to_app"_s },
                { u"description"_s, mark(u"Log out of the current session"_s) },
                { u"command"_s, QStringList{ u"logout"_s } },
                { u"dangerous"_s, true },
            }),
            vmap({
                { u"name"_s, markCtx(u"Lock"_s, u"launcher action"_s) },
                { u"icon"_s, u"lock"_s },
                { u"description"_s, mark(u"Lock the current session"_s) },
                { u"command"_s, QStringList{ u"loginctl"_s, u"lock-session"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Sleep"_s, u"launcher action"_s) },
                { u"icon"_s, u"bedtime"_s },
                { u"description"_s, mark(u"Suspend then hibernate"_s) },
                { u"command"_s, QStringList{ u"suspendThenHibernate"_s } },
            }),
            vmap({
                { u"name"_s, markCtx(u"Settings"_s, u"launcher action"_s) },
                { u"icon"_s, u"settings"_s },
                { u"description"_s, mark(u"Configure the shell"_s) },
                { u"command"_s, QStringList{ u"caelestia"_s, u"shell"_s, u"nexus"_s, u"open"_s } },
            }),
        }))
#endif
};

} // namespace caelestia::shell::config
