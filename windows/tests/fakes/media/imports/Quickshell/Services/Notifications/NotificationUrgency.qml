pragma Singleton

import QtQuick

// Icons.qml only reads this enum from the imported notification module. A
// named enum still exposes its values directly on the singleton, as the
// backend's notification enum does.
QtObject {
    enum Urgency { Low, Normal, Critical }
}
