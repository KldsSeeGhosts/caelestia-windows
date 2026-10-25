import QtQuick

// Localized stand-in for the utilities panel type reference in
// modules/notifications/Content.qml. The bounded notification host keeps
// screenState.utilities false, so this object is never rendered and never loads
// the real utilities content tree. It exists only so the original component's
// cast resolves without staging that unrelated panel.
Item {
    readonly property real nonAnimHeight: 0
}
