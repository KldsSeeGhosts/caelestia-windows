.pragma library

// Glazier names recordings from local wall-clock time. Its current default is
// recording-%Y-%m-%d_%H-%M-%S; files from the legacy recorder use
// recording_YYYYMMDD_HH-MM-SS. Build the date from its parts: Date(year, month,
// ...) takes a zero-based month, and correcting a one-based month afterwards
// rolls month-end dates into the next month.
var formats = [
    /^recording-(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})/,
    /^recording_(\d{4})(\d{2})(\d{2})_(\d{2})-(\d{2})-(\d{2})/,
];

function parse(baseName) {
    if (typeof baseName !== "string")
        return null;
    for (const format of formats) {
        const match = format.exec(baseName);
        if (match)
            return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]),
                Number(match[4]), Number(match[5]), Number(match[6]));
    }
    return null;
}
