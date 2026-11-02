.pragma library

// Dedicated video memory meter for the GPU card. Inputs are the byte counts the
// Windows backend reports for the primary adapter. Anything that is not a real
// number is rejected, so the card says "Unavailable" instead of drawing 0%.
// Zero used is real (an idle adapter); zero or negative total is not.
function evaluate(usedBytes, totalBytes) {
    const real = value => typeof value === "number" && isFinite(value);
    if (!real(usedBytes) || !real(totalBytes) || usedBytes < 0 || totalBytes <= 0)
        return { valid: false, ratio: 0, usedBytes: NaN, totalBytes: NaN };
    // Only the bar is clamped. The text keeps the true figures, so an
    // over-reported total (used above total) is shown as measured.
    return {
        valid: true,
        ratio: Math.min(usedBytes / totalBytes, 1),
        usedBytes: usedBytes,
        totalBytes: totalBytes
    };
}
