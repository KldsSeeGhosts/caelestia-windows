pragma Singleton

import QtQuick

// Windows localized adapter for the original modules/launcher/services/Actions
// singleton. AppList.appsOnly never calls it. The upstream provider builds
// detached Linux commands, so this slice exposes an inert empty search instead
// of starting a process.
QtObject {
    function query(search): var {
        return [];
    }
}
