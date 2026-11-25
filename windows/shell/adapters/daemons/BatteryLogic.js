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
    const next = {};
    let warning = null;
    for (const level of levels) {
        const key = String(level.level);
        if (percentage <= level.level && !notified[key] && !warning)
            warning = level;
        // Mark every crossed threshold, but show only the most severe.
        // Require a two-point recovery before rearming a warning.
        if (percentage <= level.level || (notified[key] && percentage < level.level + 2))
            next[key] = true;
    }
    const critical = percentage <= criticalLevel && !notified.critical;
    if (percentage <= criticalLevel || (notified.critical && percentage < criticalLevel + 2))
        next.critical = true;
    return {notified: next, warning, critical};
}
