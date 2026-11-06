pragma Singleton
import QtQuick
QtObject {
    function findChild(item, name): var { return item?.[name] ?? null; }
}
