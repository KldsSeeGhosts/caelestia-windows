pragma Singleton

import QtQuick
import Caelestia.I18n

QtObject {
    id: root

    readonly property list<var> pages: [
        // Appearance
        {
            label: Tr.tr("Wallpaper & style"),
            icon: "palette",
            description: Tr.tr("Wallpaper, fonts, colours"),
            category: "appearance",
            searchSubPages: [
                { label: Tr.tr("Wallpaper"), keywords: Tr.tr("Background images"), path: [1] },
                { label: Tr.tr("Colours"), keywords: Tr.tr("Color scheme"), path: [3] }
            ]
        },

        // Connectivity
        // TODO
        // {
        //     label: Tr.tr("Display"),
        //     icon: "monitor",
        //     description: Tr.tr("Output configuration"),
        //     category: "connectivity"
        // },
        {
            label: Tr.tr("Network"),
            icon: "wifi",
            description: Tr.tr("Wi-Fi, ethernet, VPN"),
            category: "connectivity",
            searchSubPages: [
                { label: Tr.tr("All networks"), keywords: Tr.tr("Wi-Fi wireless"), path: [5] },
                { label: Tr.tr("Saved networks"), keywords: Tr.tr("Wi-Fi wireless"), path: [6] },
                { label: Tr.tr("Add network"), keywords: Tr.tr("Wi-Fi wireless"), path: [2] }
            ]
        },
        {
            label: Tr.tr("Connected devices"),
            icon: "devices_other",
            description: Tr.tr("Bluetooth, pairing"),
            category: "connectivity",
            noFill: true,
            searchSubPages: [
                { label: Tr.tr("Pair device"), keywords: Tr.tr("Bluetooth pairing"), path: [2] }
            ]
        },
        {
            label: Tr.tr("Audio"),
            icon: "volume_up",
            description: Tr.tr("App volumes, sound devices"),
            category: "connectivity",
            searchSubPages: [
                { label: Tr.tr("App volumes"), keywords: Tr.tr("Audio sound applications"), path: [1] }
            ]
        },

        // System
        {
            label: Tr.tr("Updates"),
            icon: "update",
            description: Tr.tr("Installed versions, rollback"),
            category: "system"
        },
        {
            label: Tr.tr("Plugins"),
            icon: "extension",
            description: Tr.tr("Manage plugins"),
            category: "system"
        },

        // Shell
        {
            label: Tr.tr("Panels"),
            icon: "dock_to_bottom",
            description: Tr.tr("Dashboard, taskbar, launcher, sidebar"),
            category: "shell",
            searchSubPages: [
                { label: Tr.tr("Dashboard"), keywords: Tr.tr("Panel"), path: [1] },
                { label: Tr.tr("Taskbar"), keywords: Tr.tr("Panel bar"), path: [2] },
                { label: Tr.tr("Launcher"), keywords: Tr.tr("Panel"), path: [3] },
                { label: Tr.tr("Sidebar"), keywords: Tr.tr("Panel"), path: [4] },
                { label: Tr.tr("Utilities"), keywords: Tr.tr("Panel"), path: [5] },
                { label: Tr.tr("Workspaces"), keywords: Tr.tr("Taskbar indicators"), path: [2, 6] },
                { label: Tr.tr("Active window"), keywords: Tr.tr("Taskbar title"), path: [2, 7] },
                { label: Tr.tr("Tray"), keywords: Tr.tr("Taskbar icons"), path: [2, 8] },
                { label: Tr.tr("Status icons"), keywords: Tr.tr("Taskbar indicators"), path: [2, 9] },
                { label: Tr.tr("Clock"), keywords: Tr.tr("Taskbar date time"), path: [2, 10] }
            ]
        },
        // Windows: window management page
        {
            label: Tr.tr("Window management"),
            icon: "view_quilt",
            description: Tr.tr("Tiling, gaps, focus"),
            category: "shell"
        },
        {
            label: Tr.tr("Apps"),
            icon: "apps",
            description: Tr.tr("Default apps, favourites, hidden apps"),
            category: "shell",
            searchSubPages: [
                { label: Tr.tr("All apps"), keywords: Tr.tr("Applications"), path: [1] }
            ]
        },
        {
            label: Tr.tr("Services"),
            icon: "build",
            description: Tr.tr("Poll intervals, lyrics backend"),
            category: "shell",
            searchSubPages: [
                { label: Tr.tr("Notifications"), keywords: Tr.tr("Alerts"), path: [1] }
            ]
        },
        {
            label: Tr.tr("Language & region"),
            icon: "globe",
            description: Tr.tr("UI language, weather location, display units"),
            category: "shell"
        },

        // About
        {
            label: Tr.tr("About"),
            icon: "info",
            description: Tr.tr("System information, credits"),
            category: "about"
        },
    ]
}
