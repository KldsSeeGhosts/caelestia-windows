pragma Singleton
import QtQuick
QtObject {
    property bool enabled: false
    property bool externalWallpaperEnabled: true
    property bool active: false
    property bool underlayActive: false
    property bool embedRefused: false
    property var aboveIcons: []
    property bool coveredByForeign: false
    function updateUnderlay(): void {
        underlayActive = enabled && externalWallpaperEnabled && !embedRefused && aboveIcons.length === 0 && coveredByForeign;
    }
    onEnabledChanged: updateUnderlay()
    onExternalWallpaperEnabledChanged: updateUnderlay()
    onEmbedRefusedChanged: updateUnderlay()
    onAboveIconsChanged: updateUnderlay()
    onCoveredByForeignChanged: updateUnderlay()
    signal wallpaperChanged()
}
