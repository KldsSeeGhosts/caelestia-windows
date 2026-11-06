import QtQuick
QtObject {
    // Screen-instance creation is the dependency, not the underlay policy.
    // Recording instances lets the real adapter consume readiness without
    // creating any windows.
    property var screens: []
    property var instances: []
}
