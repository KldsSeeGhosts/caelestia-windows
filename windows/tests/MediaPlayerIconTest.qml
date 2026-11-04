import QtQuick
import "../shell/adapters/modules/dashboard/media"

// Offscreen fixture for the production media player icon path. The Windows
// backend publishes a resolved desktopEntry per player: a lowercased AUMID for
// packaged apps, an executable path for desktop apps, or the raw id when
// neither resolves. Each key must reach the app-icon path unchanged, so the
// icon provider can read an executable directly when no desktop entry matches.
// Intended runner: windows/scripts/Test-MediaPlayerIcons.ps1 -QtPrefix <Qt prefix>
QtObject {
    id: test

    property int assertions: 0

    component FakePlayer: QtObject {
        property string identity: ""
        property var desktopEntry: ""
    }

    readonly property FakePlayer packaged: FakePlayer {
        identity: "Fixture Packaged"
        desktopEntry: "fixture.packaged_abc!app"
    }
    readonly property FakePlayer desktop: FakePlayer {
        identity: "Fixture Desktop"
        desktopEntry: "C:/Program Files/Fixture/bin/fixture.exe"
    }
    readonly property FakePlayer unknown: FakePlayer {
        identity: "Fixture Unknown"
        desktopEntry: "fixture.unknown_player"
    }
    readonly property FakePlayer missing: FakePlayer {
        identity: "Fixture Missing"
    }
    readonly property FakePlayer invalid: FakePlayer {
        identity: "Fixture Invalid"
        desktopEntry: 42
    }

    readonly property PlayerIconSource packagedIcon: PlayerIconSource { player: test.packaged }
    readonly property PlayerIconSource desktopIcon: PlayerIconSource { player: test.desktop }
    readonly property PlayerIconSource unknownIcon: PlayerIconSource { player: test.unknown }
    readonly property PlayerIconSource missingIcon: PlayerIconSource { player: test.missing }
    readonly property PlayerIconSource invalidIcon: PlayerIconSource { player: test.invalid }

    function check(ok, message): void {
        test.assertions++;
        if (!ok)
            throw new Error(message);
    }

    function run(): void {
        check(test.packagedIcon.source === "image://icon/fixture-packaged-icon?fallback=image-missing",
            "a packaged AUMID uses its desktop-entry icon");
        check(test.desktopIcon.source === "image://icon/C:/Program Files/Fixture/bin/fixture.exe?fallback=image-missing",
            "an executable path stays the icon key");
        check(test.unknownIcon.source === "image://icon/fixture.unknown_player?fallback=image-missing",
            "an unresolved id stays the icon key");
        check(test.missingIcon.source === "image://icon/?fallback=image-missing",
            "a player without a desktopEntry requests the fallback");
        check(test.invalidIcon.source === "image://icon/?fallback=image-missing",
            "a non-string desktopEntry requests the fallback");
        check(!test.desktopIcon.source.includes("undefined") && !test.unknownIcon.source.includes("undefined"),
            "a heuristic miss never becomes the literal undefined key");

        console.log("CAELESTIA_MEDIA_ICONS_FIXTURE_PASS " + JSON.stringify({assertions: test.assertions}));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_MEDIA_ICONS_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
