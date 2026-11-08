import QtQuick

// Differential regression, existing-profile half: with a saved enabled:false
// the released build still treats a running Wallpaper Engine as the visible
// desktop, so the handback keeps main's source, handback and palette results.
WallpaperEngineHandbackScenario {
    existingProfile: true
}
