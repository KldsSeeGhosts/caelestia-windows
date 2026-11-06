pragma Singleton
import QtQuick
QtObject {
    function tr(text): string { return text; }
    function trCtx(text, context): string { return text; }
}
