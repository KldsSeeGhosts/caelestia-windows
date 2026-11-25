import QtQuick

QtObject {
    property string currentName
    property bool hasCurrent

    signal detachRequested(mode: string, client: var)
}
