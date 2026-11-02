pragma Singleton
import QtQuick
import "Arithmetic.js" as Arithmetic
QtObject {
    property string result
    readonly property string rawResult: result
    function evalAsync(text): void {
        try { result = Arithmetic.calculate(text.toLowerCase()); }
        catch (e) { result = "error: " + e.message; }
    }
}
