import QtQuick
import QtQuick.Dialogs as Native

// Windows adaptation of components/filedialog/FileDialog.qml. The upstream
// dialog takes `filters` as a list of extensions and builds its own filter row.
// Qt's native dialog instead needs `nameFilters` strings; without the mapping
// the file picker ignored the supplied filters and showed every file.
//
// `accepted()` is parameterless on the native dialog. Callers must read and
// decode `selectedFile`; this adapter keeps the upstream `filters`/`filterLabel`
// surface so staged components do not have to know about the difference.
Native.FileDialog {
    id: root

    property string filterLabel
    property var filters: []
    signal selected(string path)

    nameFilters: {
        const patterns = (root.filters ?? []).filter(pattern => typeof pattern === "string" && pattern.length > 0);
        if (patterns.length === 0 || patterns.indexOf("*") >= 0)
            return ["All files (*)"];
        const label = root.filterLabel.length > 0 ? root.filterLabel : "Files";
        return [`${label} (${patterns.map(pattern => "*." + pattern).join(" ")})`];
    }
}
