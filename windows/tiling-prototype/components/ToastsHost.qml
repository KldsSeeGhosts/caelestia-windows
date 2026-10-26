import QtQuick
import qs.modules.utilities.toasts

// Loaded by URL in every mode: the original toast surface is plain Caelestia
// QML (plus the staged Notifs adapter) and carries no native import. Keeping
// the module import outside shell.qml mirrors the other slice hosts; the
// original Toasts component is used unmodified and ToastItem resolves through
// the module, not the implicit directory import.
Toasts {
    id: root
}
