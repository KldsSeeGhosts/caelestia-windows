pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Windows profile configuration for the ported CPA quota drawer.
//
// Upstream reads GlobalConfig.quota, which the Linux overlay adds to the
// compiled Caelestia config plugin. This port keeps the same JSON schema in an
// optional quota.json beside shell.json, so the drawer works without rebuilding
// the plugin. Every value below is the default the original QML falls back to.
//
// Presence of cpa-agents.json is the opt-in: the drawer is enabled only when a
// CPA management config exists, unless quota.json explicitly sets "enabled".
// QML only checks that the file loads; the admin key is parsed by cpa_usage.py
// alone and is never displayed or logged.
Singleton {
    id: root

    readonly property string home: (Quickshell.env("USERPROFILE") || Quickshell.env("HOME") || "").replace(/\\/g, "/")
    readonly property string configDir: (Quickshell.env("CAELESTIA_CONFIG_DIR")
        || ((Quickshell.env("APPDATA") || root.home + "/AppData/Roaming") + "/caelestia")).replace(/\\/g, "/")
    readonly property string quotaConfigPath: Quickshell.env("CAELESTIA_QUOTA_CONFIG") || (root.configDir + "/quota.json")

    // Linux read ~/.config/omarchy/cpa-agents.json. The Windows equivalent is
    // the shell profile's config directory; CAELESTIA_CPA_CONFIG can name any
    // other file for an isolated run.
    readonly property string cpaConfigPath: Quickshell.env("CAELESTIA_CPA_CONFIG") || (root.configDir + "/cpa-agents.json")

    // Python is already a runtime dependency for the colour scheme. Reuse the
    // profile venv when one was provisioned, then the Windows launcher, then a
    // bare python on PATH. Extra args are supplied by the service.
    readonly property string schemePython: Quickshell.env("CAELESTIA_SCHEME_PYTHON")
    readonly property string python: Quickshell.env("CAELESTIA_QUOTA_PYTHON") || root.schemePython || "py"

    // Quickshell resolves these from the staged shell's StateDir/CacheDir
    // pragmas in the combined prototype. Production falls back to the per-user
    // Caelestia state location.
    readonly property string stateHome: (Quickshell.env("CAELESTIA_STATE_DIR")
        || Quickshell.env("XDG_STATE_HOME")
        || Quickshell.stateDir
        || ((Quickshell.env("LOCALAPPDATA") || root.home + "/AppData/Local") + "/caelestia-windows/state")).replace(/\\/g, "/")
    readonly property string cacheHome: (Quickshell.env("CAELESTIA_CACHE_DIR")
        || Quickshell.env("XDG_CACHE_HOME")
        || Quickshell.cacheDir
        || ((Quickshell.env("LOCALAPPDATA") || root.home + "/AppData/Local") + "/caelestia-windows/cache")).replace(/\\/g, "/")
    readonly property string usageDir: root.stateHome + "/omarchy/agents/usage"

    // Upstream defaults, overridable from quota.json.
    property int panelWidth: 384
    property int panelHeight: 520
    property int refreshIntervalMs: 60000
    property int refreshTimeoutMs: 60000
    property bool settingPresent: false
    property bool settingEnabled: false

    // Set by the FileView below. QML never reads the contents; the collector is
    // the only consumer of the admin key.
    property bool cpaConfigPresent: false
    readonly property bool configured: root.cpaConfigPresent
    // Auto-enable when a CPA config exists; quota.json can override either way.
    readonly property bool enabled: root.settingPresent ? root.settingEnabled : root.configured

    FileView {
        id: quotaFile

        path: root.quotaConfigPath
        // A missing optional file is normal; do not emit a QML warning.
        printErrors: false
        watchChanges: true

        onTextChanged: root.applySettings(quotaFile.text())
    }

    // Existence check only. Loading cpa-agents.json is a local read and its
    // text is never accessed, logged or exposed. This keeps a machine without
    // CPA completely quiet: no Python process, no warning, no drawer.
    FileView {
        id: cpaConfigFile

        path: root.cpaConfigPath
        printErrors: false
        watchChanges: true

        onLoaded: root.cpaConfigPresent = true
        onLoadFailed: root.cpaConfigPresent = false
    }

    function applySettings(raw: string): void {
        let parsed = null;
        try {
            // Notepad and some editors save a UTF-8 BOM; JSON.parse rejects it.
            parsed = JSON.parse((raw || "{}").replace(/^\uFEFF/, ""));
        } catch (error) {
            // Keep the defaults on malformed JSON; the drawer must stay usable.
            return;
        }
        if (!parsed || typeof parsed !== "object")
            return;
        if (typeof parsed.enabled === "boolean") {
            root.settingPresent = true;
            root.settingEnabled = parsed.enabled;
        }
        const geometry = (parsed.geometry && typeof parsed.geometry === "object") ? parsed.geometry : {};
        if (Number.isFinite(Number(geometry.width)))
            root.panelWidth = Math.max(280, Number(geometry.width));
        if (Number.isFinite(Number(geometry.height)))
            root.panelHeight = Math.max(240, Number(geometry.height));
        if (Number.isFinite(Number(parsed.refreshIntervalMs)))
            root.refreshIntervalMs = Math.max(10000, Number(parsed.refreshIntervalMs));
        if (Number.isFinite(Number(parsed.refreshTimeoutMs)))
            root.refreshTimeoutMs = Math.max(5000, Number(parsed.refreshTimeoutMs));
    }
}
