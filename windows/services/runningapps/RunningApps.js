// Pure projection of the existing native window model. No process enumeration,
// launching, persistent state, or MRU reordering belongs in the running pill.
function observe(toplevels) {
    return toplevels.filter(t => t && t.address && t.lastIpcObject?.class && t.wayland).map(t => ({
        id: t.address,
        appId: t.lastIpcObject.class,
        title: t.title || t.lastIpcObject.class,
        native: t.wayland,
        // The backend unmaps app/inherited cloaks but keeps shell-cloaked
        // windows on other desktops mapped. Minimized is independent of both.
        mapped: !!t.lastIpcObject.mapped,
        minimized: t.wayland.minimized,
        active: t.activated,
        desktop: t.workspace?.id ?? 0
    }));
}

function stableOrder(previous, current) {
    const present = new Set(current);
    const result = previous.filter(id => present.has(id));
    const seen = new Set(result);
    for (const id of current) {
        if (!seen.has(id)) {
            result.push(id);
            seen.add(id);
        }
    }
    return result;
}

function project(windows, previousGroups, previousWindows) {
    const byId = Object.create(null);
    const groups = Object.create(null);
    const currentWindows = new Set();
    const currentGroups = new Set();
    for (const window of windows) {
        if (!window || !window.id || !window.appId || !window.native || currentWindows.has(window.id))
            continue;
        const key = window.appId.toLowerCase();
        currentWindows.add(window.id);
        currentGroups.add(key);
        if (!window.mapped)
            continue;
        byId[window.id] = window;
        if (!groups[key])
            groups[key] = { id: key, appId: window.appId, windowIds: [], minimized: 0, active: false };
        groups[key].windowIds.push(window.id);
        groups[key].minimized += window.minimized ? 1 : 0;
        groups[key].active = groups[key].active || window.active;
    }
    // Object.keys sorts integer-looking HWND/app ids. Keep source insertion
    // order, including temporarily app-cloaked windows until they are removed.
    const windowOrder = stableOrder(previousWindows, currentWindows);
    const groupOrder = stableOrder(previousGroups, currentGroups);
    const windowIds = windowOrder.filter(id => byId[id]);
    const groupIds = groupOrder.filter(id => groups[id]);
    for (const key of groupIds) {
        const group = groups[key];
        group.windowIds = windowIds.filter(id => byId[id].appId.toLowerCase() === key);
        group.allMinimized = group.minimized === group.windowIds.length;
    }
    return { byId, groups, windowIds, groupIds, windowOrder, groupOrder };
}
