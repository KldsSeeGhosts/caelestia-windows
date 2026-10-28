// On Windows Qt keeps native origins but scales screen sizes to logical units.
function intervals(screen, screens, edge) {
    if (!screen || !screens)
        return [];
    const scale = screen.devicePixelRatio || 1;
    const right = screen.x + screen.width * scale;
    const bottom = screen.y + screen.height * scale;
    const result = [];
    for (const other of screens) {
        if (!other || other === screen)
            continue;
        const otherScale = other.devicePixelRatio || 1;
        const otherRight = other.x + other.width * otherScale;
        const otherBottom = other.y + other.height * otherScale;
        // Logical sizes are rounded by Qt, so recovered native edges may differ.
        const tolerance = Math.max(scale, otherScale);
        let start, end, origin, length;
        if (edge === "right" && Math.abs(right - other.x) <= tolerance) {
            start = Math.max(screen.y, other.y);
            end = Math.min(bottom, otherBottom);
            origin = screen.y;
            length = screen.height;
        } else if (edge === "bottom" && Math.abs(bottom - other.y) <= tolerance) {
            start = Math.max(screen.x, other.x);
            end = Math.min(right, otherRight);
            origin = screen.x;
            length = screen.width;
        } else {
            continue;
        }
        // Region coordinates are integers. Round inward, never onto an outer edge.
        const from = Math.max(0, Math.ceil((start - origin) / scale));
        const to = Math.min(length, Math.floor((end - origin) / scale));
        if (to > from)
            result.push({ start: from, end: to });
    }
    return result;
}

function extraWidth(value) {
    return typeof value === "number" && isFinite(value) ? Math.max(0, Math.min(48, value)) : 12;
}

function rect(x1, y1, x2, y2) {
    x1 = Math.ceil(x1); y1 = Math.ceil(y1);
    x2 = Math.floor(x2); y2 = Math.floor(y2);
    return x2 > x1 && y2 > y1 ? { x: x1, y: y1, width: x2 - x1, height: y2 - y1 } : null;
}

// These closed-edge rectangles are both the input mask and hover predicates.
// Existing upstream panel regions handle the open panel and outer edges.
function triggerRects(screen, screens, width, height, border, minBorder, rounding,
                      osdY, osdHeight, utilitiesX, utilitiesWidth, extra, osdEnabled, utilitiesEnabled) {
    const result = { osd: [], utilities: [] };
    if (!screen || extra <= 0)
        return result;
    const baseline = Math.max(minBorder, border);
    const add = (list, r) => { if (r) list.push(r); };
    const left = Math.max(0, utilitiesX - rounding);
    const right = Math.min(width, utilitiesX + utilitiesWidth + rounding);
    const cornerTop = height - baseline - rounding;
    for (const span of intervals(screen, screens, "right")) {
        if (osdEnabled)
            add(result.osd, rect(width - baseline - extra, Math.max(span.start, osdY - rounding),
                                 width, Math.min(span.end, osdY + osdHeight + rounding)));
        if (utilitiesEnabled)
            add(result.utilities, rect(Math.max(left, width - baseline - extra), Math.max(span.start, cornerTop),
                                       right, Math.min(span.end, height)));
    }
    if (utilitiesEnabled) {
        for (const span of intervals(screen, screens, "bottom"))
            add(result.utilities, rect(Math.max(left, span.start), cornerTop - extra,
                                       Math.min(right, span.end), height));
    }
    return result;
}

function contains(rectangles, x, y) {
    return rectangles.some(r => x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height);
}
