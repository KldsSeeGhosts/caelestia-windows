import QtQuick

// Injectable projection of the native singleton. Older pins expose neither
// read validity nor write capability, so they remain unknown and read-only.
QtObject {
    id: root

    property var source: null
    readonly property bool ready: source !== null
    readonly property bool profileKnown: source?.profileKnown === true
    readonly property int profile: profileKnown ? source.profile : -1
    readonly property string rawOverlayGuid: typeof source?.rawOverlayGuid === "string"
        ? source.rawOverlayGuid : ""
    readonly property bool observing: source?.observing === true
    readonly property bool writeSupported: source?.writeSupported === true
    readonly property bool performanceClaim: source?.hasPerformanceProfile === true
    readonly property var mappedProfiles: !writeSupported ? []
        : performanceClaim ? [0, 1, 2] : [0, 1]
    readonly property bool writeResultAvailable: typeof source?.profileWriteResult === "function"
    readonly property string lastError: typeof source?.lastError === "string" && source.lastError
        ? source.lastError
        : typeof source?.profileKnown !== "boolean"
            ? "This backend cannot verify the current power profile."
            : !profileKnown ? "The current power profile is unknown." : ""

    signal profileWriteResult(int requestedProfile, bool ok, string error)

    readonly property Connections results: Connections {
        target: root.source
        ignoreUnknownSignals: true
        function onProfileWriteResult(requestedProfile, ok, error) {
            root.profileWriteResult(requestedProfile, ok, error);
        }
    }

    function setProfile(target): bool {
        if (mappedProfiles.indexOf(target) < 0)
            return false;
        source.profile = target;
        // Submission only. The native result follows set success and re-read.
        return true;
    }
}
