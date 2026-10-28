// Qt on Windows preserves native screen origins, but scales screen sizes.
// Compare native boundaries, then use the resulting flags in local logical px.
function adjacent(screen, screens, edge) {
    if (!screen || !screens)
        return false;
    const scale = screen.devicePixelRatio || 1;
    const right = screen.x + screen.width * scale;
    const bottom = screen.y + screen.height * scale;
    for (const other of screens) {
        if (!other || other === screen)
            continue;
        const otherScale = other.devicePixelRatio || 1;
        const otherRight = other.x + other.width * otherScale;
        const otherBottom = other.y + other.height * otherScale;
        // Qt rounds logical sizes, so the recovered native edge can be off
        // by up to one scaled logical pixel.
        const tolerance = Math.max(scale, otherScale);
        if (edge === "right" && Math.abs(right - other.x) <= tolerance
                && Math.min(bottom, otherBottom) > Math.max(screen.y, other.y))
            return true;
        if (edge === "bottom" && Math.abs(bottom - other.y) <= tolerance
                && Math.min(right, otherRight) > Math.max(screen.x, other.x))
            return true;
    }
    return false;
}

function extraWidth(value) {
    return typeof value === "number" && isFinite(value) ? Math.max(0, Math.min(48, value)) : 12;
}

function rightThreshold(width, minThickness, panelX, extra) {
    return Math.min(width - minThickness - extra, panelX);
}

function bottomThreshold(height, minThickness, thickness, panelHeight, rounding, extra) {
    return height - Math.max(minThickness, thickness + panelHeight) - rounding - extra;
}
