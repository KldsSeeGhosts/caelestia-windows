pragma Singleton

import Quickshell
import Caelestia.I18n

Singleton {
    property var _regexCache: ({})

    function percent(value: int): string {
        // TRANSLATORS: %1 = a number
        return Tr.tr("%1%").arg(value);
    }

    function percentOne(value: real): string {
        return percent(Math.round(value * 100));
    }

    function testRegexList(filterList: list<string>, target: string): bool {
        const regexChecker = /^\^.*\$$/;
        for (const filter of filterList) {
            if (regexChecker.test(filter)) {
                let re = _regexCache[filter];
                if (re === undefined) {
                    // Windows: a user pattern that does not compile is skipped (and
                    // remembered as such). The engine's error text carries the
                    // pattern, so it is never logged.
                    try {
                        re = new RegExp(filter);
                    } catch (error) {
                        re = null;
                    }
                    _regexCache[filter] = re;
                }
                if (re && re.test(target))
                    return true;
            } else {
                if (filter === target)
                    return true;
            }
        }
        return false;
    }
}
