pragma Singleton
import Quickshell
Singleton {
    property list<ShellScreen> screens: Quickshell.screens
    function isExcluded(screen: ShellScreen): bool { return false; }
}
