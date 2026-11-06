pragma Singleton
import QtQuick
QtObject {
    property var contents: ({})
    property var views: []
    function changed(path): void {
        for (const view of views)
            if (view.path === path && view.watchChanges)
                view.fileChanged();
    }
}
