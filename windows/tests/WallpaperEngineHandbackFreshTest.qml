import QtQuick

// Differential regression, fresh-profile half: the same scenario must give the
// new fresh-profile policy, where a disabled engine is never the visible
// source and the handback changes nothing.
WallpaperEngineHandbackScenario {
    existingProfile: false
}
