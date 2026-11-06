import QtQuick
import StagedFixture
QtObject {
    id: root
    property string cacheRoot: ""
    property var items: []
    property bool historyEnabled: true
    property string status: "ready"
    property string lastError: ""
    property int generation: 0
    signal imageReady(string id, string url)
    signal pasteReady(string id)
    signal pasteDeferred(string message)
    signal operationFailed(string operation, string message)
    signal openUrl(string url)
    Component.onCompleted: generation = Driver.attach(root)
    Component.onDestruction: Driver.detach(generation)
    function shutdown(): void { Driver.shutdown(generation); }
    function refresh(): void { Driver.enqueue(generation, "items", [{id: "synthetic", kind: "text", text: "synthetic"}]); }
    function setActive(active): void {}
    function copy(id): void { Driver.forbiddenCalls++; }
    function paste(id): void { Driver.enqueue(generation, "paste", id); }
    function remove(id): void { Driver.forbiddenCalls++; }
    function clear(): void { Driver.forbiddenCalls++; }
    function openItem(id): void { Driver.forbiddenCalls++; }
    function requestImage(id): void { Driver.enqueue(generation, "image", id); }
    function openSettings(): void { Driver.forbiddenCalls++; }
}
