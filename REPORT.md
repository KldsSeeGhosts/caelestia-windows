# Windows tiling configuration

Implemented on `t3/tiling-config`, based on integration `4697ffa8`.
No pushes, PRs, Linear changes, takeover, or native Interactive runs.

`Caelestia.Config.GlobalConfig.windows` is a Windows-only map in ConfigRoot.
The facade consumes `windows.tiling` from the profile's watched `shell.json`.
Config changes stop the current session, apply admission rules and gaps, then
use the existing enable/mutex gate. Observe and disabled stop the tiler;
a held mutex retains the existing refusal toast.

## Schema

```json
{
  "windows": {
    "tiling": {
      "enabled": true,
      "mode": "observe",
      "gapsIn": 10,
      "gapsOut": 10,
      "include": ["exe:editor.exe", "class:Chrome_WidgetWin_*"],
      "exclude": ["title:*Private*"],
      "float": ["title:*Dialog*"],
      "monitors": {"Secondary*": false}
    }
  }
}
```

| Field | Default / behavior |
| --- | --- |
| `enabled` | `false`; only boolean `true` enables the selected mode |
| `mode` | `observe`; `interactive` requires a non-empty include list; smoke downgrades it |
| `gapsIn`, `gapsOut` | 10/10 integer DIPs; finite numbers round and clamp to 0..100 |
| `include` | Empty; array of strings or semicolon-separated string |
| `exclude`, `float` | Empty; same syntax; both leave matching windows unmanaged |
| `monitors` | Object of Qt screen-name wildcard patterns to booleans; all enabled by default; false excludes |

Patterns are case-insensitive whole-value wildcards, not regex. `exe:` selects
executable filename/basename; `class:` selects Win32 class; `title:` selects
title. Unprefixed patterns preserve the shared app ID/exe/class dialect.
Float, exclusion and disabled-monitor matches always win. A false blanket
monitor pattern also wins over true exceptions. Inner-gap parameters can be
applied on both neighboring tiles by the backend layout.

Explicit launcher switches override environment variables, which override
corresponding profile fields:

- `-Tiling -TilingMode Disabled|Observe|Interactive` /
  `CAELESTIA_WINDOWS_TILING=off|observe|interactive`.
- `-TilingIncluded`, `-TilingExcluded` /
  `CAELESTIA_WINDOWS_TILING_INCLUDED`, `CAELESTIA_WINDOWS_TILING_EXCLUDED`.
  Explicit empty launcher lists clear those lists. Float/monitor exclusions
  remain in effect. Direct launches can clear an env list with its
  `_OVERRIDE=1` companion.
- `-TilingConfigFile <shell.json>` copies only `windows.tiling` into the
  bounded launcher's isolated profile. Edit that profile for live reload.
  `-BuildRoot` reads binaries; `-RunRoot`/`-ProfileRoot` select local output.

The ported KSG importer maps `wm.enabled`, `wm.gap`, `wm.padding`, preserving
10/10 defaults and KSG's 0..40 clamp, rounding fractional DIPs for the native
integer properties. Imported mode is always Observe. Reviewed Caelestia
rules/monitors survive the merge. KSG has no persisted user rule list to
translate; bundled regex/compound rules remain manual migration decisions.

## Build and checks

Backend commit `6a17ae6019d6606cc2d3e8178623bfe53b227515`,
branch `windows/tiling-config`, adds typed exe/class/screen selectors and
`supportsScopedRules`. The gitlink and `windows/sources.lock.json` agree.
The commit is local and must be transferred/published with integration;
it is available in `windows/deps/quickshell` and the backend worktree at
`windows/.local/tiling-backend`. Older backends refuse Interactive when
typed rules cannot be enforced.

Built a separate backend and portable plugins in `windows/.local/build`
with Windows Qt 6.11.2, clang-cl 20.1.8, VS 2022 and Ninja. The supplied
integration build was read only. Build commands/logs and smoke evidence
are archived in `windows/validation/2026-10-26-tiling-config/`.

- Combined smoke passed.
- Native Observe smoke logged `CAELESTIA_TILING_OPTIONS gapsIn=10 gapsOut=10`;
  initial/final snapshots had `backendEnabled=false`.
- Profile-only native smoke passed: 10/10 load, watched reload to 12/14,
  rule arrays/monitor map retained, then watched disable unloaded the backend.
- Pure QML fixture: 180 assertions passed, including config/env precedence,
  smoke downgrade, live disable, unsupported-rule refusal and mutex toast.
- Native backend policy suite: 28 tests passed, including typed selectors
  and monitor exclusion/transfer with fake window facts.
- File-only importer smoke passed; prerequisite report confirms matching pins.

No native Interactive placement or live mutex contention is claimed.
The existing KSG tiler remained running. Observe constructs the native
controller and retains its existing parked-window rescue behavior.
