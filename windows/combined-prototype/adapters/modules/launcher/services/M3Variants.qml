pragma Singleton
import QtQuick
import qs.utils
Searcher {
    readonly property string currentScheme: "Fixed Windows palette"
    readonly property string currentVariant: "Unavailable"
    list: []
    function reload(): void {}
}
