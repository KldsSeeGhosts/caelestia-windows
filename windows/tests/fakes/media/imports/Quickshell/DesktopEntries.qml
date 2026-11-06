pragma Singleton

import QtQuick

// Fake desktop-entry catalog for the media fixture. Only the app-icon rows use
// it; one known key stands in for an entry the real catalog indexes.
QtObject {
    function heuristicLookup(name) {
        if (name === "fixture.known_app")
            return { icon: "fixture-known-icon", categories: ["AudioVideo"] };
        return undefined;
    }
}
