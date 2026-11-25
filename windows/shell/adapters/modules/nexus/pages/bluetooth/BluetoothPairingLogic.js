.pragma library

function isMacOnly(value) {
    const text = String(value || "").trim().toUpperCase();
    return /^([0-9A-F]{2}[:-]){5}[0-9A-F]{2}$/.test(text) || /^[0-9A-F]{12}$/.test(text);
}

function isUnnamed(device) {
    const name = String(device ? (device.deviceName || device.name) : "").trim();
    return name.length === 0 || isMacOnly(name);
}

function compareDevices(a, b) {
    return (isUnnamed(a) - isUnnamed(b))
        || ((b && b.pairing ? 1 : 0) - (a && a.pairing ? 1 : 0))
        || String(a && a.name || "").localeCompare(String(b && b.name || ""));
}
