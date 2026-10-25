import QtQuick
import Quickshell.Windows

// Loaded by URL only after Brightness.enabled. Referencing the native
// Quickshell.Windows.Brightness singleton constructs it; its constructor only
// creates the worker pool and registers the active instance. No probe starts
// until query()/probe() is invoked. query() and probe() are deferred to the
// backend's after-first-frame hook when called during startup.
//
// The shared build is still at the old pin, which has no strict-route members.
// strictSupported is false there and strictRoutes stays undefined, so the pure
// adapter refuses writes instead of reaching the legacy setBrightness() path
// (which retries \\.\LCD, falls back to software gamma and then reports
// ok = true). Once the gitlink moves, the same wrapper forwards the strict
// property, the one-shot brightnessWriteResult() and clearSoftwareDimming().
QtObject {
    id: root

    readonly property string backendId: "Quickshell.Windows.Brightness"
    readonly property bool strictSupported: typeof Brightness.strictRoutes === "boolean"
        && typeof Brightness.brightnessWriteResult === "function"
    // Deliberately a `var`: undefined when the pinned native singleton lacks
    // the strict API, which is exactly what the adapter feature-detects.
    property var strictRoutes: strictSupported ? Brightness.strictRoutes : undefined

    signal queried(string screenName, bool available, bool isDdc, real brightness)
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
