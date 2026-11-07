import QtQuick

// Paths imports the staged services graph. Its managed-host type must resolve,
// but this file-URL fixture must never launch, adopt or stop a capture process.
QtObject {
    readonly property var snapshot: ({ owned: false, launched: false, closeAttempted: false })
    signal reloadReady(bool ok)
    signal quitReady(bool ok)

    function forbidden(): void { throw new Error("FILE_URL_CAPTURE_HOST_ACTION_FORBIDDEN"); }
    function acquire(image, windowClass, options): void { forbidden(); }
    function command(args): bool { forbidden(); return false; }
    function close(restart): bool { forbidden(); return false; }
    function quit(): bool { forbidden(); return false; }
    function prepareReload(): bool { forbidden(); return false; }
}
