import QtQuick
import Quickshell.Windows

// Loaded by URL only after Brightness.enabled. Referencing the native
// Quickshell.Windows.Brightness singleton constructs it; its constructor only
// creates the worker pool and registers the active instance. No probe starts
// until query()/probe() is invoked. query() and probe() are deferred to the
// backend's after-first-frame hook when called during startup.
//
// The shared build is at a pin with the strict-route members but without the
// id-carrying query API. strictSupported is true there while queryIdsSupported
// stays false: queryRequest remains undefined, which is what the adapter
// feature-detects, so unmatched query results only ever feed read-only
// display state and the controls gate stays closed. Once the gitlink moves,
// the same wrapper forwards queryRequest()/queryFinished() unchanged.
QtObject {
    id: root

    readonly property string backendId: "Quickshell.Windows.Brightness"
    readonly property bool strictSupported: typeof Brightness.strictRoutes === "boolean"
        && typeof Brightness.brightnessWriteResult === "function"
    // Deliberately a `var`: undefined when the pinned native singleton lacks
    // the strict API, which is exactly what the adapter feature-detects.
    property var strictRoutes: strictSupported ? Brightness.strictRoutes : undefined
    // The native singleton is process-wide and survives a wrapper reload, so
    // request ids it issues are process-unique and strictly increasing. At a
    // pin without queryRequest this stays undefined and the adapter keeps the
    // controls read-only rather than guessing which request a result answers.
    readonly property bool queryIdsSupported: typeof Brightness.queryRequest === "function"
    // Deliberately a `var` like strictRoutes: a callable when supported,
    // undefined otherwise, matching the adapter's feature detection.
    readonly property var queryRequest: queryIdsSupported
        ? ((screenName) => Brightness.queryRequest(screenName))
        : undefined

    signal queried(string screenName, bool available, bool isDdc, real brightness)
    // requestId is a `real`: the native id is a qint64 and `int` would truncate it.
    signal queryFinished(real requestId, string screenName, bool available, bool isDdc, real brightness)
    signal brightnessSetFinished(string screenName, bool ok)
    signal brightnessWriteResult(string screenName, real value, bool ok, string method, string error)
    signal routeChanged(string screenName, string route)
    signal systemBrightnessChanged(string screenName, real brightness)

    function query(screenName): void {
        Brightness.query(screenName);
    }

    // Exposed for parity with the native API. The adapter never calls probe():
    // it shares startProbe()'s gamma reset with query() and only omits the
    // DDC/CI read, so it is not a write-free alternative.
    function probe(screenName): void {
        Brightness.probe(screenName);
    }

    function refresh(screenName): void {
        Brightness.refresh(screenName);
    }

    function setBrightness(screenName, isDdc, value): void {
        Brightness.setBrightness(screenName, isDdc, value);
    }

    function methodFor(screenName): string {
        const route = Brightness.methodFor(screenName);
        return typeof route === "string" ? route : "";
    }

    // The adapter prefers this over assigning the read-only `strictRoutes`
    // binding. Enabling is one-way in the native backend.
    function setStrictRoutes(enabled): void {
        if (strictSupported)
            Brightness.strictRoutes = enabled === true;
    }

    function clearSoftwareDimming(screenName): void {
        if (typeof Brightness.clearSoftwareDimming === "function")
            Brightness.clearSoftwareDimming(screenName);
    }

    property Connections nativeConnections: Connections {
        target: Brightness
        ignoreUnknownSignals: true
        function onQueried(screenName, available, isDdc, brightness): void {
            root.queried(screenName, available, isDdc, brightness);
        }
        function onQueryFinished(requestId, screenName, available, isDdc, brightness): void {
            root.queryFinished(requestId, screenName, available, isDdc, brightness);
        }
        function onBrightnessSetFinished(screenName, ok): void {
            root.brightnessSetFinished(screenName, ok);
        }
        function onBrightnessWriteResult(screenName, value, ok, method, error): void {
            root.brightnessWriteResult(screenName, value, ok, method, error);
        }
        function onRouteChanged(screenName, route): void {
            root.routeChanged(screenName, route);
        }
        function onSystemBrightnessChanged(screenName, brightness): void {
            root.systemBrightnessChanged(screenName, brightness);
        }
    }
}
