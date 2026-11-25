.pragma library

function sortedLevels(levels) {
    const values = [];
    for (let i = 0; i < (levels ? levels.length : 0); ++i) {
        const level = levels[i];
        if (level && Number.isFinite(level.level))
            values.push(level);
    }
    return values.sort((a, b) => a.level - b.level);
}

function warnings(notified, percentage, levels, criticalLevel) {
    const next = Object.assign({}, notified);
    let warning = null;
    for (const level of levels) {
        const key = String(level.level);
        if (percentage <= level.level && !notified[key] && !warning)
            warning = level;
        // Mark every crossed threshold, but show only the most severe.
        // Discharge readings can fluctuate. Only a confirmed AC transition
        // clears the latches in the monitor.
        if (percentage <= level.level)
            next[key] = true;
    }
    const critical = percentage <= criticalLevel && !notified.critical;
    if (percentage <= criticalLevel)
        next.critical = true;
    return {notified: next, warning, critical};
}

function powerTransition(current, known, onBattery) {
    if (!known)
        return {source: current, event: "unknown"};
    const source = onBattery ? 1 : 0;
    if (current === source)
        return {source, event: "unchanged"};
    if (current === -1)
        return {source, event: "seed"};
    return {source, event: source === 1 ? "unplugged" : "plugged"};
}
