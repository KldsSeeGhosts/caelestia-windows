pragma Singleton
import QtQuick
import StagedFixture
QtObject {
    readonly property string stateDir: Driver.profile + "/state"
    readonly property string cacheDir: Driver.profile + "/cache"
    function env(name): string { return String(Driver.environment[name] ?? ""); }
    function shellPath(path): string { return Driver.profile + "/shell/" + path; }
}
