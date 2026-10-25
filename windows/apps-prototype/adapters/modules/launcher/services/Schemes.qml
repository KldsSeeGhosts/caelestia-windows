pragma Singleton

import QtQuick

// Windows localized adapter for the original modules/launcher/services/Schemes
// singleton. AppList.appsOnly never calls it, and no scheme CLI is available in
// this slice.
QtObject {
    function query(search): var {
        return [];
    }

    function reload(): void {}
}
