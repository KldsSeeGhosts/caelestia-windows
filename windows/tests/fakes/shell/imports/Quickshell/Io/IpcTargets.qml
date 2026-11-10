pragma Singleton

import QtQuick

// Target-keyed registry behind the recording IpcHandler. It mirrors the part
// of Quickshell's IPC registry a fixture needs: look up a target and invoke one
// of its functions with positional arguments.
QtObject {
    id: root

    property var targets: ({})

    function register(handler): void {
        if (!handler || !handler.target)
            return;
        targets = Object.assign({}, targets, {[handler.target]: handler});
    }
    function unregister(handler): void {
        if (!handler || targets[handler.target] !== handler)
            return;
        const next = Object.assign({}, targets);
        delete next[handler.target];
        targets = next;
    }
    function has(target): bool {
        return Object.prototype.hasOwnProperty.call(targets, target);
    }
    function find(target): var {
        return has(target) ? targets[target] : null;
    }
    function call(target, name, args): var {
        const handler = find(target);
        if (!handler)
            throw new Error("No IpcHandler with target \"" + target + "\"");
        const fn = handler[name];
        if (typeof fn !== "function")
            throw new Error("IpcHandler \"" + target + "\" has no function \"" + name + "\"");
        return fn.apply(handler, args ?? []);
    }
}
