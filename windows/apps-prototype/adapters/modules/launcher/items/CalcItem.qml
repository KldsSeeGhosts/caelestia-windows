import QtQuick

// Windows localized adapter. See ActionItem.qml: unusable in this bounded host
// because AppList.appsOnly keeps the list on applications only.
Item {
    property var list

    implicitHeight: 0
}
