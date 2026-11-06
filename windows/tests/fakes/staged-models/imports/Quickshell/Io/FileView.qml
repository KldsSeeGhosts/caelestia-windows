import QtQuick
import StagedFixture
QtObject {
    property string path: ""
    property bool blockLoading: false
    property bool atomicWrites: true
    property bool watchChanges: false
    property bool printErrors: false
    signal loaded()
    signal loadFailed(int error)
    signal saved()
    signal saveFailed(int error)
    signal fileChanged()
    function text(): string { Driver.readPaths.push(path); return String(Driver.files[path] ?? ""); }
    function reload(): void {}
    // Writes remain uncommitted until the fixture emits saved/saveFailed.
    function setText(value): void {
        Driver.writes.push({path: path, text: value, atomic: atomicWrites});
    }
}
