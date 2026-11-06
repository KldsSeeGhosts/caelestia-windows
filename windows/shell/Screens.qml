pragma Singleton

import Quickshell

// The production shell follows every physical monitor, including hotplug.
// ShellState and the production drawer Variants share this exact screen list.
Singleton {
    readonly property list<ShellScreen> screens: Quickshell.screens
    function isExcluded(screen: ShellScreen): bool { return false; }
}
