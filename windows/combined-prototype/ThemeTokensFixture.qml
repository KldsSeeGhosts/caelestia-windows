import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

ShellRoot {
    id: root
    property int phase: 0

    ThemeTokens {
        id: exporter
        outputPath: Quickshell.env("THEME_TOKEN_TEST_FILE")
        bundledFontPath: "C:/fixture/font.ttf"
        rounding: fixtureRounding
        uiFont: Qt.font({ family: root.phase === 0 ? "Google Sans Flex" : "Example UI" })
    }
    QtObject {
        id: fixtureRounding
        property int small: 8
        property int medium: 12
        property int large: 16
        property int full: 2147483647
    }
    FileView {
        id: reader
        path: ""
        onLoaded: {
            const data = JSON.parse(text());
            if (root.phase === 0) {
                if (data.version !== 1 || data.mode !== "dark"
                        || data.colours.primary !== "#123456"
                        || data.radii.normal !== 12 || data.font.family !== "Google Sans Flex"
                        || data.font.file !== "C:/fixture/font.ttf")
                    return root.fail("initial tokens");
                root.phase = 1;
                fixtureRounding.medium = 19;
                Colours.load(JSON.stringify({ mode: "light", colours: { primary: "abcdef" } }), false);
                check.restart();
            } else {
                if (data.mode !== "light" || data.colours.primary !== "#abcdef"
                        || data.radii.normal !== 19 || data.font.family !== "Example UI" || data.font.file !== null)
                    return root.fail("change-driven rewrite");
                console.log("THEME_TOKENS_FIXTURE_PASS");
                Qt.quit();
            }
        }
        onLoadFailed: root.fail("read failed")
    }
    Timer {
        id: check
        interval: 500
        onTriggered: {
            if (reader.path === "")
                reader.path = exporter.outputPath;
            reader.reload();
        }
    }
    function fail(message: string): void {
        console.error("THEME_TOKENS_FIXTURE_FAIL " + message);
        Qt.exit(1);
    }
    Component.onCompleted: {
        Colours.load(JSON.stringify({ mode: "dark", colours: { primary: "123456" } }), false);
        check.start();
    }
}
