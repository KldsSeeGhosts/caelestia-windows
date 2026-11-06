pragma Singleton
import QtQuick
import StagedFixture
QtObject {
    function openAccessSettings(): void { Driver.forbiddenCalls++; }
}
