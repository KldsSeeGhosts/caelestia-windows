import QtQuick

Instantiator {
    id: root
    property QtObject window: null
    required property int frameLimit
    property int frames: 0
    signal counted(int count)
    readonly property bool subscribed: object?.target != null

    onWindowChanged: frames = 0

    // Disconnect the native frame signal itself once readiness has evidence.
    // Keep the source identity on the connection. Qt can finish delivering
    // signals from a replaced window after its handler has disconnected.
    model: root.window ? [root.window] : []
    delegate: Connections {
        required property QtObject modelData
        target: root.frames < root.frameLimit ? modelData : null
        function onFrameSwapped(): void {
            if (!target || modelData !== root.window || root.frames >= root.frameLimit)
                return;
            const count = root.frames + 1;
            root.frames = count;
            root.counted(count);
        }
    }
}
