import QtQuick
import Quickshell

// Process-local application fonts. Never install fonts or fetch at runtime.
QtObject {
    readonly property bool ready: symbols.status === FontLoader.Ready
        && regular.status === FontLoader.Ready && bold.status === FontLoader.Ready
        && italic.status === FontLoader.Ready && boldItalic.status === FontLoader.Ready

    readonly property FontLoader symbols: FontLoader {
        source: Quickshell.shellPath("assets/nerd-font-symbols/SymbolsNerdFontMono-Regular.ttf")
    }
    readonly property FontLoader regular: FontLoader {
        source: Quickshell.shellPath("assets/caskaydia-cove/CaskaydiaCoveNerdFont-Regular.ttf")
    }
    readonly property FontLoader bold: FontLoader {
        source: Quickshell.shellPath("assets/caskaydia-cove/CaskaydiaCoveNerdFont-Bold.ttf")
    }
    readonly property FontLoader italic: FontLoader {
        source: Quickshell.shellPath("assets/caskaydia-cove/CaskaydiaCoveNerdFont-Italic.ttf")
    }
    readonly property FontLoader boldItalic: FontLoader {
        source: Quickshell.shellPath("assets/caskaydia-cove/CaskaydiaCoveNerdFont-BoldItalic.ttf")
    }
}
