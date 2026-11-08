import QtQuick
QtObject {
    id: root
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: false
    property bool blockLoading: false
    property bool atomicWrites: false
    signal loaded()
    signal loadFailed()
    signal fileChanged()
    signal saved()
    signal saveFailed(var error)
    function text(): string { return String(Files.contents[path] ?? ""); }
    function reload(): void {
        if (Object.prototype.hasOwnProperty.call(Files.contents, path))
            loaded();
        else
            loadFailed();
    }
    function setText(text): void {
        if (!path)
            return;
        Files.contents[path] = text;
        if (watchChanges)
            fileChanged();
    }
    Component.onCompleted: { Files.views.push(root); reload(); }
}
