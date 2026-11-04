import QtQuick
QtObject {
    id: root
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: false
    signal loaded()
    signal loadFailed()
    signal fileChanged()
    function text(): string { return String(Files.contents[path] ?? ""); }
    function reload(): void {
        if (Object.prototype.hasOwnProperty.call(Files.contents, path))
            loaded();
        else
            loadFailed();
    }
    Component.onCompleted: { Files.views.push(root); reload(); }
}
