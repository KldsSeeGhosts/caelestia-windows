import QtQuick
import Quickshell.Windows

// Loaded by URL only after Brightness.enabled. Referencing the native
// Quickshell.Windows.Brightness singleton constructs it; its constructor only
// creates the worker pool and registers the active instance. No probe starts
// until query()/probe() is invoked. query() and probe() are deferred to the
// backend's after-first-frame hook when called during startup.
//
// The backend exposes no per-query error text, no per-write result beyond a
// boolean that is true even after an internal gamma fallback, and no
// acknowledgement that a write used the requested route. BrightnessService.qml
// treats a route change as the failure signal and never assumes success.
QtObject {
    id: root

    readonly property string backendId: "Quickshell.Windows.Brightness"

    signal queried(string screenName, bool available, bool isDdc, real brightness)
    signal brightnessSetFinished(string screenName, bool ok)
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

    property Connections nativeConnections: Connections {
        target: Brightness
        function onQueried(screenName, available, isDdc, brightness): void {
            root.queried(screenName, available, isDdc, brightness);
        }
        function onBrightnessSetFinished(screenName, ok): void {
            root.brightnessSetFinished(screenName, ok);
        }
        function onRouteChanged(screenName, route): void {
            root.routeChanged(screenName, route);
        }
        function onSystemBrightnessChanged(screenName, brightness): void {
            root.systemBrightnessChanged(screenName, brightness);
        }
    }
}
