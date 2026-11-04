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

// The window the user last had focused in this application. The facade's
// `active` bit only follows the current activation, so it cannot answer this
// after the user switches to another app. The model records the native
// foreground handle per group and drops it when that window closes.
function lastActiveWindow(group, windows, lastActive) {
    if (!group || !Array.isArray(group.windowIds) || group.windowIds.length === 0)
        return "";
    const remembered = lastActive ? lastActive[group.id] : "";
    if (remembered && group.windowIds.includes(remembered) && windows[remembered])
        return remembered;
    return group.windowIds.find(id => windows[id] && windows[id].active) || group.windowIds[0];
}

// Drop remembered windows that closed or left their group. Keyed by group id;
// never reorders the window list.
function retainLastActive(groups, lastActive) {
    const retained = Object.create(null);
    for (const key of Object.keys(lastActive || {})) {
        const id = lastActive[key];
        if (groups[key] && groups[key].windowIds.includes(id))
            retained[key] = id;
    }
    return retained;
}

// Windows 11 taskbar click on one application.
// - A not-focused app (or one with minimized windows only) focuses its
//   last-active window, restoring it if it is minimized.
// - A focused single-window app minimizes.
// - A focused multi-window app cycles to its next window in stable order; the
//   order never follows focus, so repeated clicks walk the whole list.
// `foregroundId` is the native foreground window, not a facade value retained
// while the shell itself has focus.
function clickAction(group, windows, foregroundId, lastActive) {
    if (!group || !Array.isArray(group.windowIds) || group.windowIds.length === 0)
        return { action: "none", id: "" };
    const ids = group.windowIds;
    const at = ids.indexOf(foregroundId);
    const focused = at >= 0 && !!windows[foregroundId]
        && windows[foregroundId].appId.toLowerCase() === group.id;
    if (!focused)
        return { action: "activate", id: lastActiveWindow(group, windows, lastActive) };
    if (ids.length === 1)
        return { action: "minimize", id: ids[0] };
    return { action: "activate", id: ids[(at + 1) % ids.length] };
}
