pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.Windows as Native
import qs.services

// Resolve the original shell's asset namespace inside the isolated stage.
QtObject {
    readonly property string home: (Quickshell.env("USERPROFILE") || "").replace(/\\/g, "/")

    readonly property string cache: Quickshell.cacheDir.replace(/\\/g, "/")
    readonly property url configFile: "file:///" + (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/") + "/shell.json"

    // Profile-local state. The staged shell.qml pins Quickshell.stateDir to
    // <build>/combined-prototype-profile/state, and the scheme bridge writes
    // <profile>/state/caelestia/scheme.json (the upstream CLI's own layout).
    readonly property string state: (Quickshell.stateDir + "/caelestia").replace(/\\/g, "/")

    // Windows may redirect these folders (for example OneDrive folder backup),
    // so ask the shell for their real paths instead of appending to the profile.
    readonly property string pictures: (Native.KnownFolders.pictures || (home + "/Pictures")).replace(/\\/g, "/")
    readonly property string videos: (Native.KnownFolders.videos || (home + "/Videos")).replace(/\\/g, "/")

    readonly property string wallsdir: resolveWallpapersDir(pictures, home + "/Pictures", GlobalConfig.paths.wallpaperDir, Quickshell.env("CAELESTIA_WALLPAPER_DIR"), imageProbes)
    readonly property string recsdir: Recorder.outputDir

    // Answers from Native.KnownFolders.probeImages, keyed by folderKey(path).
    // The probe enumerates on a worker thread, because a redirected Pictures
    // folder can sit on an unavailable share. wallsdir uses the Known Folder
    // until an answer proves otherwise, so it changes at most once, and only
    // when the legacy folder is the one holding the wallpapers.
    property var imageProbes: ({})
    readonly property var probeTargets: wallpaperProbeTargets(pictures, home + "/Pictures", GlobalConfig.paths.wallpaperDir, Quickshell.env("CAELESTIA_WALLPAPER_DIR"))
    property var requestedProbes: ({})

    onProbeTargetsChanged: requestProbes()
    Component.onCompleted: {
        Native.KnownFolders.imagesProbed.connect(recordProbe);
        requestProbes();
    }

    function folderKey(path): string {
        return normalizePath(path).toLowerCase();
    }
    function requestProbes(): void {
        for (const path of probeTargets) {
            const key = folderKey(path);
            if (requestedProbes[key])
                continue;
            requestedProbes[key] = true;
            Native.KnownFolders.probeImages(path);
        }
    }
    function recordProbe(path, found): void {
        const next = Object.assign({}, imageProbes);
        next[folderKey(path)] = found;
        imageProbes = next;
    }
    function normalizePath(path): string {
        return Native.KnownFolders.normalizePath(String(path || ""));
    }
    function joinPath(dir, name): string {
        // A drive-relative "D:" joins without a separator: "D:/a" would leave
        // the drive's current directory. An empty dir joins to a relative name.
        if (!dir || dir.endsWith("/") || /^[A-Za-z]:$/.test(dir))
            return dir + name;
        return dir + "/" + name;
    }
    function samePath(a, b): bool {
        return normalizePath(a).toLowerCase() === normalizePath(b).toLowerCase();
    }
    function expandPath(path: string): string {
        if (!path || !path.trim())
            return "";
        return path.trim().replace(/\\/g, "/").replace(/^(?:~|\$(?:HOME|\{HOME\}))(?=\/|$)/, home);
    }
    // Which folder the wallpaper rule can decide without looking at the disk:
    // { fixed } when an environment or configured path, or an unredirected
    // Pictures folder, settles it; { known, legacy } when images decide.
    function wallpaperPlan(knownPictures, legacyPictures, configured, envOverride): var {
        const env = envOverride ? expandPath(envOverride) : "";
        if (env)
            return { fixed: normalizePath(env) };

        const knownDefault = normalizePath(joinPath(normalizePath(knownPictures), "Wallpapers"));
        const explicit = expandPath(configured);

        // Older configs could contain the computed Pictures Known Folder
        // default. Treat that exact value as "not configured" so the legacy
        // fallback below can still find wallpapers the old adapter scanned.
        if (explicit && !samePath(explicit, knownDefault))
            return { fixed: normalizePath(explicit) };

        // No redirection: the Known Folder is the legacy folder, so the answer
        // is the same whatever the folder holds and nothing needs probing.
        const legacyDefault = normalizePath(joinPath(normalizePath(legacyPictures), "Wallpapers"));
        if (samePath(legacyDefault, knownDefault))
            return { fixed: knownDefault };

        return { known: knownDefault, legacy: legacyDefault };
    }
    function wallpaperProbeTargets(knownPictures, legacyPictures, configured, envOverride): var {
        const plan = wallpaperPlan(knownPictures, legacyPictures, configured, envOverride);
        return plan.fixed !== undefined ? [] : [plan.known, plan.legacy];
    }
    // probes maps folderKey(path) to whether the folder holds an image; a
    // missing entry means the probe has not answered yet.
    //  1. CAELESTIA_WALLPAPER_DIR, then an explicit paths.wallpaperDir.
    //  2. The Known Folder's Wallpapers, if it holds an image.
    //  3. The legacy profile Wallpapers, if it differs and holds an image.
    //  4. Otherwise the Known Folder's Wallpapers.
    // Until the Known Folder is known to be empty the answer is the Known
    // Folder, so a slow probe never switches to the legacy folder early.
    function resolveWallpapersDir(knownPictures, legacyPictures, configured, envOverride, probes): string {
        const plan = wallpaperPlan(knownPictures, legacyPictures, configured, envOverride);
        if (plan.fixed !== undefined)
            return plan.fixed;
        if (probes[folderKey(plan.known)] !== false)
            return plan.known;
        return probes[folderKey(plan.legacy)] === true ? plan.legacy : plan.known;
    }
    function shortenHome(path: string): string { return path.replace(home, "~"); }
    // Use Windows default applications, not upstream's mpv/thunar commands.
    function openRecording(path: string): bool {
        return Qt.openUrlExternally(absolutePath(path));
    }
    function revealRecording(path: string): bool {
        const local = path.replace(/\\/g, "/");
        return Qt.openUrlExternally(absolutePath(local.slice(0, local.lastIndexOf("/"))));
    }
    function deleteRecording(path: string): bool {
        // The list shows every .mp4 in the output folder (upstream); only delete
        // files Glazier reported as finished.
        if (!Recorder.owns(path)) {
            Recorder.lastError = "Only recordings Glazier reported can be deleted here.";
            return false;
        }
        return CUtils.deleteFile(absolutePath(path));
    }
    function absolutePath(path: string): string {
        if (!path || !path.trim())
            return "";
        if (path.startsWith("file:"))
            return path;
        if (path.startsWith("root:/"))
            return Qt.resolvedUrl("../" + path.slice(6)).toString();
        const local = path.replace(/\\/g, "/").replace(/^~(?=\/|$)|^\$(?:HOME|\{HOME\})(?=\/|$)/, home);
        const encoded = local.split("/").map(segment => encodeURIComponent(segment)).join("/");
        if (/^[A-Za-z]:\//.test(local))
            return "file:///" + local.slice(0, 2) + encoded.slice(4);
        if (local.startsWith("//"))
            return "file:" + encoded;
        if (local.startsWith("/"))
            return "file://" + encoded;
        return Qt.resolvedUrl("../" + encoded).toString();
    }
}
