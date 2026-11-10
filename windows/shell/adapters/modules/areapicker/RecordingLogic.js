// Windows keeps screen origins in native virtual-desktop pixels even when Qt
// scales the screen's size. Scale local offsets, never the global origin.
function region(selection, screen, dpr) {
    if (!(dpr > 0) || !selection || !screen)
        return null;
    var x = Math.max(0, Math.round(selection.x * dpr));
    var y = Math.max(0, Math.round(selection.y * dpr));
    var right = Math.min(Math.round(screen.width * dpr), Math.round((selection.x + selection.width) * dpr));
    var bottom = Math.min(Math.round(screen.height * dpr), Math.round((selection.y + selection.height) * dpr));
    var w = Math.floor((right - x) / 2) * 2;
    var h = Math.floor((bottom - y) / 2) * 2;
    return w >= 2 && h >= 2 ? { x: screen.x + x, y: screen.y + y, w: w, h: h } : null;
}

function localRegion(region, screen, dpr) {
    if (!region || !(dpr > 0) || region.x < screen.x || region.y < screen.y
            || region.x >= screen.x + screen.width * dpr || region.y >= screen.y + screen.height * dpr)
        return null;
    return { x: (region.x - screen.x) / dpr, y: (region.y - screen.y) / dpr,
        width: region.w / dpr, height: region.h / dpr };
}

function timer(seconds) {
    var total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
    return String(Math.floor(total / 60)).padStart(2, "0") + ":" + String(total % 60).padStart(2, "0");
}

function action(state) {
    return state === "recording" ? "pause" : state === "paused" ? "resume" : "record";
}

function startArgs(region) {
    if (!region || !["x", "y", "w", "h"].every(key => Number.isInteger(region[key]))
            || region.w < 2 || region.h < 2)
        return null;
    return ["--record", "--region", [region.x, region.y, region.w, region.h].join(","),
        "--no-ui", "--mic", "off", "--system-sound", "off"];
}
