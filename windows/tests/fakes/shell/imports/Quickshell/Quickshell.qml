pragma Singleton
import QtQuick
QtObject {
    property var environment: ({CAELESTIA_COMBINED_LIVE: "1"})
    property var screens: []
    function env(name): string { return String(environment[name] ?? ""); }
    function shellPath(path): string { return "C:/fixture/" + path; }
}
