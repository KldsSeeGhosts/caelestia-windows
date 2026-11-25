.pragma library

function text(value) {
    return typeof value === "string" ? value : "";
}

function commandKey(command) {
    if (!command || typeof command.length !== "number")
        return "";
    const parts = [];
    for (let index = 0; index < command.length; ++index) {
        if (typeof command[index] !== "string")
            return "";
        parts.push(command[index]);
    }
    return JSON.stringify(parts);
}

function keyOf(parts) {
    return JSON.stringify(parts);
}

function copyAction(action, command) {
    return {
        enabled: action.enabled !== false,
        name: text(action.name),
        icon: text(action.icon),
        description: text(action.description),
        command: command,
        dangerous: action.dangerous === true
    };
}

const translations = [
    { legacy: ["caelestia", "shell", "nexus", "open"], windows: ["settings"] },
    { legacy: ["suspendThenHibernate"], windows: ["suspend"] },
    { legacy: ["loginctl", "lock-session"], windows: ["lock"] },
    { legacy: ["poweroff"], windows: ["shutdown"] }
];

const stockLinuxKeys = [
    keyOf(["autocomplete", "calc"]),
    keyOf(["autocomplete", "scheme"]),
    keyOf(["autocomplete", "wallpaper"]),
    keyOf(["autocomplete", "variant"]),
    keyOf(["caelestia", "wallpaper", "-r"]),
    keyOf(["setMode", "light"]),
    keyOf(["setMode", "dark"]),
    keyOf(["poweroff"]),
    keyOf(["reboot"]),
    keyOf(["logout"]),
    keyOf(["loginctl", "lock-session"]),
    keyOf(["suspendThenHibernate"]),
    keyOf(["caelestia", "shell", "nexus", "open"])
];

function translatedCommand(command) {
    const key = commandKey(command);
    for (const entry of translations)
        if (key === keyOf(entry.legacy))
            return entry.windows;
    return null;
}

const stockLinuxMetadata = [
    ["Calculator", "calculate", "Do simple maths equations (powered by Qalc)"],
    ["Scheme", "palette", "Change the current colour scheme"],
    ["Wallpaper", "wallpaper", "Change the current wallpaper"],
    ["Variant", "colors", "Change the current scheme variant"],
    ["Random", "casino", "Switch to a random wallpaper"],
    ["Light", "light_mode", "Change the scheme to light mode"],
    ["Dark", "dark_mode", "Change the scheme to dark mode"],
    ["Shutdown", "power_settings_new", "Shutdown the system", true],
    ["Reboot", "cached", "Reboot the system", true],
    ["Logout", "exit_to_app", "Log out of the current session", true],
    ["Lock", "lock", "Lock the current session"],
    ["Sleep", "bedtime", "Suspend then hibernate"],
    ["Settings", "settings", "Configure the shell"]
];

function isStockLinuxList(actions) {
    if (!actions || actions.length !== stockLinuxKeys.length)
        return false;
    for (let index = 0; index < actions.length; ++index) {
        const action = actions[index];
        const [name, icon, description, dangerous] = stockLinuxMetadata[index];
        if (!action || action.decodeValid === false || action.enabled === false
            || commandKey(action.command) !== stockLinuxKeys[index]
            || (action.name !== name && action.name !== "\u0001launcher action\u0004" + name)
            || action.icon !== icon
            || (action.description !== description && action.description !== "\u0001" + description)
            || (action.dangerous === true) !== (dangerous === true)
            || action.verb || action.target || action.aumid || action.uri
            || action.workingDir || action.args?.length)
            return false;
    }
    return true;
}

function migrateOne(action) {
    const command = action && action.command ? action.command : [];
    const translated = action.decodeValid !== false && !action.verb && !action.target && !action.aumid && !action.uri
        && !action.workingDir && !action.args?.length
        ? translatedCommand(command) : null;
    if (translated)
        return copyAction(action, translated);
    return action;
}

function windowsDefaultActions() {
    return [
        { name: "Calculator", icon: "calculate", description: "Arithmetic and functions", command: ["autocomplete", "calc"] },
        { name: "Settings", icon: "settings", description: "Open Caelestia settings", command: ["settings"] },
        { name: "Screenshot", icon: "screenshot_region", description: "Capture an area or window", command: ["screenshot"] },
        { name: "Screenshot history", icon: "history", description: "Edit and export recent screenshots", command: ["screenshotHistory"] },
        { name: "Record screen", icon: "screen_record", description: "Record the screen", command: ["record"] },
        { name: "Wallpaper", icon: "wallpaper", description: "Browse wallpaper folder", command: ["autocomplete", "wallpaper"] },
        { name: "Choose wallpaper file", icon: "image", description: "Open the Windows image picker", command: ["chooseWallpaper"] },
        { name: "Scheme", icon: "palette", description: "Change the current colour scheme", command: ["autocomplete", "scheme"] },
        { name: "Variant", icon: "colors", description: "Change the current scheme variant", command: ["autocomplete", "variant"] },
        { name: "Light", icon: "light_mode", description: "Change the scheme to light mode", command: ["setMode", "light"] },
        { name: "Dark", icon: "dark_mode", description: "Change the scheme to dark mode", command: ["setMode", "dark"] },
        { name: "Shutdown", icon: "power_settings_new", description: "Shutdown the system", command: ["shutdown"], dangerous: true },
        { name: "Reboot", icon: "cached", description: "Reboot the system", command: ["reboot"], dangerous: true },
        { name: "Hibernate", icon: "bedtime", description: "Hibernate the system", command: ["hibernate"], dangerous: true },
        { name: "Reboot to firmware", icon: "settings_applications", description: "Reboot into the system firmware interface", command: ["firmware"], dangerous: true },
        { name: "Logout", icon: "exit_to_app", description: "Log out of the current session", command: ["logout"], dangerous: true },
        { name: "Lock", icon: "lock", description: "Lock the current session", command: ["lock"] },
        { name: "Sleep", icon: "bedtime", description: "Suspend the system", command: ["suspend"] }
    ];
}

function migrateActions(values) {
    const actions = [];
    for (let index = 0; values && index < values.length; ++index)
        actions.push(values[index]);
    if (isStockLinuxList(actions))
        return windowsDefaultActions().map(action => ({enabled: true, ...action}));
    return actions.map(migrateOne);
}
