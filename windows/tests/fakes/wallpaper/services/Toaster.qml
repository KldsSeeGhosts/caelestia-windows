pragma Singleton
import QtQuick
QtObject {
    property var calls: []
    function toast(title, body, icon): void { calls.push({title, body, icon}); }
}
