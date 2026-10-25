import QtQuick

// Windows localized adapter. The bounded apps host keeps the original
// AppList.appsOnly hook enabled, so this delegate is never instantiated. It
// only satisfies the original list's static component declarations; the
// launcher action provider, calculator, scheme and variant services are not
// staged and no process is started here.
Item {
    property var modelData
    property var list

    implicitHeight: 0
}
