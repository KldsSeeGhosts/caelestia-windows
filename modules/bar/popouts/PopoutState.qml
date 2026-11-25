import QtQuick

QtObject {
    property string currentName
    property bool hasCurrent

    signal detachRequested(mode: string)
    signal inspectWindowRequested(client: var)
}
