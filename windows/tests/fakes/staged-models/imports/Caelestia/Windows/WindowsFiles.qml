pragma Singleton
import QtQuick
import StagedFixture

// Existence checks stay synthetic: only paths the fixture seeded into
// Driver.files count as files, so no real filesystem state leaks in.
QtObject {
    function isFile(path): bool { return Driver.files[path] !== undefined; }
}
