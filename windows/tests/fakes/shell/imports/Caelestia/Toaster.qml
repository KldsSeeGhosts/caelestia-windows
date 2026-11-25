pragma Singleton

import QtQuick

QtObject {
    property var calls: []

    function toast(title, body, icon, type): void {
        calls = calls.concat([{title: String(title), body: String(body), icon: String(icon), type: type}]);
    }
}
