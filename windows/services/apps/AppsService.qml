import QtQuick
import "../../../utils/scripts/fzf.js" as Fzf
import "../../../utils/scripts/fuzzysort.js" as Fuzzy

// Windows adaptation of the bounded parts of modules/launcher/services/Apps.qml.
//
// This object imports no Quickshell and no Caelestia.Models/AppDb. It owns the
// read-only catalog projection (states, names, icons, filtering), the original
// launcher search contract (`search`/`query`, `list`, `keys`, `weights`,
// `useFuzzy`) and the launch policy. A native catalog facade and a frequency
// store are injected; backends may be fakes in tests.
//
// Upstream `Apps` sorts its list through AppDb (favourites first, then launch
// frequency, then name) and delegates filtering to utils/Searcher (fzf by
// default, fuzzysort when configured). Both upstream search libraries are
// imported unchanged, so ranking stays the original one; the frequency store is
// a profile-local JSON replacement. Enumeration and search never launch:
// `catalog.execute` is only reachable through `launch` after the separate
// launch opt-in and the membership/terminal checks.
QtObject {
    id: root

    // Injected native facade (NativeAppCatalog or a test fake) exposing:
    //   applications (model with .values of DesktopEntry-like objects),
    //   scanCompleted (bool), scanError (string), execute(entry) -> bool.
    property var catalog: null
    property bool enabled: false
    property bool launchEnabled: false

    // A known component failure. The native wrapper reports shape/scan errors
    // through scanError; this property covers a failed QML component load.
    property string catalogError: ""

    // Injected frequency store (AppFrequencyStore or a test fake) exposing
    // frequencies (map), frequencyFor(id) -> int, increment(id) -> int.
    property var frequencyStore: null

    // Injected from GlobalConfig by the singleton facade.
    property var favouriteApps: []
    property var hiddenApps: []
    property string specialPrefix: "@"
    property bool useFuzzy: false

    // Upstream Searcher state. search() derives a local prefix spec, so these
    // remain the public query() spec and keep their upstream defaults.
    property string key: "name"
    property var keys: [root.key]
    property var weights: [1]
    property var extraOpts: ({})

    property var _regexCache: ({})

    // --- Native lifecycle -------------------------------------------------
    // The Windows backend has no per-scan result. `scanCompleted` becomes true
    // on DesktopEntries.applicationsChanged, which the backend emits after the
    // AppsFolder enumeration returns; it emits it for an empty scan too. A scan
    // that fails internally therefore reaches this adapter as "empty" rather
    // than "failed" (see windows/audits/M2-APPS-BACKEND-GAPS.md). `failed` is
    // reserved for a reported component/shape error.
    readonly property string nativeError: {
        if (!enabled || !catalog)
            return "";
        const reported = catalog.scanError;
        if (typeof reported === "string" && reported.length > 0)
            return reported;
        if (catalog.scanCompleted === true) {
            const model = catalog.applications;
            if (!model || !model.values)
                return "The Windows app catalog reported no application model.";
        }
        return "";
    }

    // lastError is the one error string consumers may display.
    readonly property string lastError: {
        if (!enabled)
            return "";
        if (catalogError)
            return catalogError;
        return nativeError;
    }

    readonly property bool scanCompleted: enabled && !catalogError
        && catalog !== null && catalog.scanCompleted === true

    // --- Catalog ----------------------------------------------------------
    // Hidden-app filters keep upstream semantics (exact id or ^...$ regex).
    // Non-object entries and entries without an id and name are rejected
    // instead of being projected as applications; DesktopEntry.isValid() uses
    // the same non-empty name rule.
    readonly property var entries: {
        if (!scanCompleted)
            return [];
        const values = catalog?.applications?.values;
        if (!values)
            return [];
        const filtered = [];
        for (const entry of values) {
            if (!entry || typeof entry !== "object")
                continue;
            const id = typeof entry.id === "string" ? entry.id : "";
            const name = typeof entry.name === "string" ? entry.name : "";
            if (id.length === 0 || name.length === 0)
                continue;
            if (matchesFilterList(hiddenApps, id))
                continue;
            filtered.push(entry);
        }
        return filtered;
    }
    readonly property int count: entries.length

    // Five explicit states.
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (catalogError)
            return "failed";
        if (!catalog)
            return "scanning";
        if (nativeError.length > 0)
            return "failed";
        if (catalog.scanCompleted !== true)
            return "scanning";
        return entries.length > 0 ? "ready" : "empty";
    }
    readonly property bool ready: status === "ready"
    readonly property bool scanning: status === "scanning"
    readonly property bool empty: status === "empty"
    readonly property bool failed: status === "failed"
    readonly property bool disabled: status === "disabled"

    readonly property string reason: {
        if (status === "disabled")
            return "Windows app search is disabled.";
        if (status === "failed")
            return "The Windows app catalog is unavailable: " + lastError;
        if (status === "scanning")
            return "Scanning Windows applications from the Start menu and Apps folder.";
        if (status === "empty")
            return "The Windows app catalog scan completed with no applications.";
        return count + " application(s) observed. "
            + (launchEnabled
            ? "Explicit launch is enabled."
            : "Read-only observation: launching is disabled.");
    }

    // Short, plain copy for the bounded host's existing empty-state layout.
    readonly property string statusTitle: {
        switch (status) {
        case "disabled": return "Windows app search is disabled";
        case "scanning": return "Scanning applications";
        case "failed": return "App catalog unavailable";
        case "empty": return "No applications found";
        default: return "";
        }
    }
    readonly property string statusDescription: {
        switch (status) {
        case "disabled": return "App enumeration stays off until the Windows app catalog opt-in is enabled.";
        case "scanning": return "Reading the Start menu and installed application list.";
        case "failed": return lastError;
        case "empty": return "The Windows app catalog scan found no applications.";
        default: return "";
        }
    }

    // Original AppItem fallback name. The entry's own icon is passed to
    // Quickshell.iconPath(..., "image-missing") unchanged.
    function iconName(entry): string {
        if (!entry)
            return "image-missing";
        const icon = typeof entry.icon === "string" ? entry.icon : "";
        return icon.length > 0 ? icon : "image-missing";
    }

    function nameFor(entry): string {
        return entry && typeof entry.name === "string" ? entry.name : "";
    }

    // Upstream Strings.testRegexList semantics: only ^...$ filters are regular
    // expressions; anything else must match the id exactly. Invalid patterns
    // are ignored instead of throwing during a binding.
    function matchesFilterList(filters, target): bool {
        if (!filters || typeof target !== "string" || target.length === 0)
            return false;
        for (const filter of filters) {
            if (typeof filter !== "string")
                continue;
            if (/^\^.*\$$/.test(filter)) {
                let re = _regexCache[filter];
                if (!re) {
                    try {
                        re = new RegExp(filter);
                    } catch (error) {
                        continue;
                    }
                    _regexCache[filter] = re;
                }
                if (re.test(target))
                    return true;
            } else if (filter === target) {
                return true;
            }
        }
        return false;
    }

    function isFavourite(id): bool {
        return matchesFilterList(favouriteApps, id);
    }

    // --- Frequency-sorted list -------------------------------------------
    // Mirrors AppDb.getSortedApps(): favourites first, then launch frequency
    // descending, then name. The wrappers preserve the AppEntry-shaped fields
    // upstream Searcher reads through `keys`.
    readonly property var list: {
        const source = entries;
        // Explicit read so a store change rebuilds the ordered list.
        const frequencySnapshot = frequencyStore ? frequencyStore.frequencies : null;
        const wrappers = source.map(entry => makeWrapper(entry));
        wrappers.sort(compareWrappers);
        return wrappers;
    }

    function makeWrapper(entry): var {
        return {
            entry: entry,
            id: entry.id,
            name: entry.name,
            comment: typeof entry.comment === "string" ? entry.comment : "",
            execString: typeof entry.execString === "string" ? entry.execString : "",
            startupClass: typeof entry.startupClass === "string" ? entry.startupClass : "",
            genericName: typeof entry.genericName === "string" ? entry.genericName : "",
            categories: listText(entry.categories),
            keywords: listText(entry.keywords),
            runInTerminal: entry.runInTerminal === true,
            icon: typeof entry.icon === "string" ? entry.icon : "",
            frequency: frequencyFor(entry.id)
        };
    }

    function listText(value): string {
        if (typeof value === "string")
            return value;
        if (value && typeof value.length === "number")
            return Array.prototype.join.call(value, " ");
        return "";
    }

    function frequencyFor(id): int {
        if (!frequencyStore || typeof frequencyStore.frequencyFor !== "function")
            return 0;
        const value = frequencyStore.frequencyFor(id);
        return typeof value === "number" && isFinite(value) && value > 0 ? Math.floor(value) : 0;
    }

    function compareNames(a, b): int {
        if (typeof a.localeCompare === "function")
            return a.localeCompare(b);
        return a < b ? -1 : a > b ? 1 : 0;
    }

    function compareWrappers(a, b): int {
        const aFavourite = isFavourite(a.id);
        const bFavourite = isFavourite(b.id);
        if (aFavourite !== bFavourite)
            return aFavourite ? -1 : 1;
        if (a.frequency !== b.frequency)
            return b.frequency - a.frequency;
        return compareNames(a.name, b.name);
    }

    // --- Upstream Searcher contract --------------------------------------
    // The original Searcher keeps a cached fzf Finder and rewrites `keys` in
    // search(). Both are QML properties; doing either inside the original
    // launcher list's model binding produced binding-loop diagnostics because
    // the binding then depends on a property search() writes. The finder and
    // the prefix key spec are therefore local values here: the same upstream
    // search libraries and ordering, without mutating reactive state from a
    // binding. `keys`/`weights` remain the public spec for query().
    function selectorText(spec, item): string {
        return spec.keys.map(property => item[property]).join(" ");
    }

    function fuzzyPrepare(spec): var {
        return list.map(entry => {
            const prepared = {
                _item: entry
            };
            for (const property of spec.keys)
                prepared[property] = Fuzzy.prepare(entry[property]);
            return prepared;
        });
    }

    function queryWith(spec, search): var {
        search = transformSearch(String(search ?? "").trim().replace(/\s+/g, " "));
        if (!search)
            return [...list];

        if (useFuzzy) {
            const prepared = fuzzyPrepare(spec);
            if (prepared.length === 0)
                return [];
            return Fuzzy.go(search, prepared, Object.assign({
                all: true,
                keys: spec.keys,
                scoreFn: result => spec.weights.reduce((total, weight, index) => total + result[index].score * weight, 0)
            }, extraOpts)).map(result => result.obj._item);
        }

        const finder = new Fzf.Finder(list, Object.assign({
            selector: item => root.selectorText(spec, item)
        }, extraOpts));
        return finder.find(search).sort((a, b) => {
            if (a.score === b.score)
                return selectorText(spec, a.item).trim().length - selectorText(spec, b.item).trim().length;
            return b.score - a.score;
        }).map(result => result.item);
    }

    // Kept for consumers that read the upstream Searcher state.
    readonly property var fuzzyPrepped: useFuzzy ? fuzzyPrepare({
        keys: keys
    }) : []

    function transformSearch(search: string): string {
        return search;
    }

    function selector(item: var): string {
        return selectorText({
            keys: keys
        }, item);
    }

    function query(search): var {
        return queryWith({
            keys: keys,
            weights: weights
        }, search);
    }

    // Preserved upstream special prefixes (@i/@c/@d/@e/@w/@g/@k/@t). The
    // default query only matches names; @t filters terminal entries.
    function search(search): var {
        const prefix = specialPrefix;
        const text = String(search ?? "");
        let spec = {
            keys: ["name"],
            weights: [1]
        };
        let fieldPrefix = false;

        if (text.startsWith(`${prefix}i `)) {
            spec = {keys: ["id", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        } else if (text.startsWith(`${prefix}c `)) {
            spec = {keys: ["categories", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        } else if (text.startsWith(`${prefix}d `)) {
            spec = {keys: ["comment", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        } else if (text.startsWith(`${prefix}e `)) {
            spec = {keys: ["execString", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        } else if (text.startsWith(`${prefix}w `)) {
            spec = {keys: ["startupClass", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        } else if (text.startsWith(`${prefix}g `)) {
            spec = {keys: ["genericName", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        } else if (text.startsWith(`${prefix}k `)) {
            spec = {keys: ["keywords", "name"], weights: [0.9, 0.1]};
            fieldPrefix = true;
        }

        if (!fieldPrefix && !text.startsWith(`${prefix}t `))
            return queryWith(spec, text).map(entry => entry.entry);

        const results = queryWith(spec, text.slice(prefix.length + 2)).map(entry => entry.entry);
        if (text.startsWith(`${prefix}t `))
            return results.filter(entry => entry && entry.runInTerminal === true);
        return results;
    }

    // --- Launch policy ----------------------------------------------------
    // Upstream wraps terminal applications in assets/wrap_term_launch.sh with
    // GlobalConfig.general.apps.terminal. That Linux wrapper does not exist
    // here, and the Windows backend's DesktopEntry.execute() deliberately
    // ignores runInTerminal. Terminal entries are therefore reported as an
    // unsupported launch instead of being started without a terminal.
    readonly property bool terminalLaunchSupported: false
    property int launchRequests: 0
    property int launchesIssued: 0
    property string lastLaunchError: ""
    property string lastLaunchId: ""

    // Disabling the catalog also clears launch bookkeeping, like every other
    // projection in this object.
    onEnabledChanged: {
        if (!enabled) {
            launchRequests = 0;
            launchesIssued = 0;
            lastLaunchError = "";
            lastLaunchId = "";
        }
    }

    function canLaunch(entry): bool {
        if (!launchEnabled || !ready || !entry || typeof entry !== "object")
            return false;
        if (entry.runInTerminal === true)
            return false;
        return list.some(wrapper => wrapper.entry === entry);
    }

    // Returns whether a native execute was requested. The Windows backend has
    // no per-command result: a true return means the request was permitted and
    // dispatched, not that the application started.
    function launch(entry): bool {
        launchRequests++;
        lastLaunchError = "";
        lastLaunchId = entry && typeof entry.id === "string" ? entry.id : "";

        if (!enabled) {
            lastLaunchError = "Windows app search is disabled.";
            return false;
        }
        if (!launchEnabled) {
            lastLaunchError = "Application launching is disabled; this session is read-only.";
            return false;
        }
        if (!ready) {
            lastLaunchError = "The Windows app catalog is not ready.";
            return false;
        }
        if (!entry || typeof entry !== "object") {
            lastLaunchError = "Unknown application entry.";
            return false;
        }
        if (!list.some(wrapper => wrapper.entry === entry)) {
            lastLaunchError = "The application is not in the current catalog.";
            return false;
        }
        if (entry.runInTerminal === true) {
            lastLaunchError = "Terminal application launch is not supported on Windows.";
            return false;
        }

        const id = typeof entry.id === "string" ? entry.id : "";
        if (frequencyStore && typeof frequencyStore.increment === "function" && id.length > 0)
            frequencyStore.increment(id);

        const executed = catalog && typeof catalog.execute === "function"
            ? catalog.execute(entry) === true : false;
        if (!executed) {
            lastLaunchError = "The Windows app catalog could not start the application.";
            return false;
        }
        launchesIssued++;
        return true;
    }
}
