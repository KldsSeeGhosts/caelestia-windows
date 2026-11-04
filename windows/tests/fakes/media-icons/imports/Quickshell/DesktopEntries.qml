pragma Singleton

import QtQuick

// Fake desktop-entry catalog for the media-icon fixture. The Windows backend
// resolves a packaged player's desktopEntry to its lowercased AUMID, which the
// real catalog indexes. Desktop players publish an executable path that no
// desktop entry matches, and an unresolved player keeps its raw id.
QtObject {
    function heuristicLookup(name) {
        if (name === "fixture.packaged_abc!app")
            return { icon: "fixture-packaged-icon", categories: ["AudioVideo"] };
        return undefined;
    }
}
