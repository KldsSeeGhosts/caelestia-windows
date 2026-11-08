pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.utils

// Records whether this profile existed before this build first saw it. The
// marker is established and written synchronously at shell start, before any
// current-run writer can create theme tokens, palette state or a wallpaper
// record. A fresh first start that crashes after one of those writes therefore
// still reads back as fresh on the next start instead of turning into an
// upgrade.
//
// Only a missing marker is classified. Earlier Caelestia state is the signal:
// every earlier build created <profile>/state/caelestia, while Start-Caelestia
// creates only the empty <profile>/state for a fresh profile. The installer's
// profile-owner.json is not used because every install writes it, fresh or
// upgrade, so it separates nothing. Once written, the marker is the authority
// for every later start.
Singleton {
    id: root

    readonly property string markerPath: `${Paths.state}/wallpaper/profile.json`
    // "fresh" or "existing" after classification. The empty value only exists
    // while the marker is being read during construction.
    property string profile: ""
    readonly property bool existing: profile === "existing"
    property bool ready: false
    property string error: ""

    // Write-only unless the marker already exists. blockWrites makes setText
    // synchronous, so the marker is on disk before ThemeTokens or the palette
    // bridge can write anything in this run. It also creates its parent
    // directory, which the wallpaper record later reuses.
    FileView {
        id: markerFile
        path: root.markerPath
        preload: false
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onSaveFailed: error => root.error = "could not write the profile marker: " + String(error)
    }

    Component.onCompleted: {
        if (Native.FsUtils.classify(root.markerPath) === "file") {
            root.applyMarker(markerFile.text());
            root.ready = true;
            return;
        }
        // The Caelestia state directory, not the installer's <profile>/state:
        // Start-Caelestia creates the latter for every start, fresh or not.
        root.profile = Native.FsUtils.classify(Paths.state) === "dir" ? "existing" : "fresh";
        markerFile.setText(JSON.stringify({version: 1, profile: root.profile}, null, 2) + "\n");
        root.ready = true;
    }

    function applyMarker(content): void {
        try {
            const marker = JSON.parse(String(content ?? "").replace(/^\uFEFF/, ""));
            if (marker && marker.version === 1 && (marker.profile === "fresh" || marker.profile === "existing")) {
                root.profile = marker.profile;
                return;
            }
        } catch (error) {
            // A malformed marker still proves a previous run classified this
            // profile. Preserving its saved wallpapers is the safe reading.
        }
        root.profile = "existing";
    }
}
