# Windows tiling service

M3-2 stages 4/5 groundwork: constructing the backend's `Tiling` controller
behind bounded opt-ins, applying its options without enabling it, and
explaining fitting failures on Caelestia's original toast surface. The M3-1
audit's one-active-tiler and construction-side-effect rules apply.

| file | role |
| --- | --- |
| `TilingService.qml` | pure state object: opt-in policy, interactive gating, backend projection, bounded failure list and toast decisions |
| `NativeTilingBackend.qml` | thin wrapper that imports `Quickshell.Windows` and feature-detects the allowlist/telemetry members; loaded by URL only for observe/interactive |
| `Tiling.qml` | singleton facade staged at `services/Tiling.qml`; owns the environment opt-ins, the native `Loader` and the `Toaster.toast` bridge |

## Profile configuration

`shell.json` is loaded and watched by `Caelestia.Config.GlobalConfig`.
The Windows-only `windows` map holds service extensions; the facade validates
`windows.tiling` on each change.

```json
{
  "windows": {
    "tiling": {
      "enabled": true,
      "mode": "observe",
      "gapsIn": 5,
      "gapsOut": 10,
      "singleWindowGapsOut": 20,
      "borderColours": true,
      "include": ["exe:editor.exe", "class:Chrome_WidgetWin_*"],
      "exclude": ["title:*Private*"],
      "float": ["title:*Dialog*"],
      "monitors": {"\\\\.\\DISPLAY2": false}
    }
  }
}
```

- Defaults: disabled, Observe mode when enabled, empty rules,
  all monitors enabled. Modes are `observe` and `interactive`; disabled selects
  `off`. Invalid modes stay off. Gaps are finite numbers, rounded and clamped
  to 0..100 integer DIPs; invalid/missing gaps use their defaults below.
- `gapsIn`: default 5 DIPs per window side, giving 10 DIPs total between two
  tiled windows. Existing explicit values retain their per-side meaning.
- `gapsOut`: default 10 DIPs between tiled windows and the monitor work area.
- `singleWindowGapsOut`: default 20 DIPs, replacing `gapsOut` when exactly
  one window is tiled on that monitor and workspace. Minimized and maximized
  windows do not count as tiled. Maximized windows keep Windows semantics and
  fill the work area; the Hyprland maximized-window gap rule is not applied.
- `borderColours`: default true. On Windows 11 build 22000+, managed windows
  use the scheme primary when focused and a dim onSurfaceVariant otherwise.
  The upstream 0xe6/0x11 alpha values are blended against the scheme surface
  because DWM accepts opaque colours. Focus and scheme changes update live.
  Every touched border returns to `DWMWA_COLOR_DEFAULT` when the window leaves
  management, the option or tiler is disabled, or the shell exits normally.
  Older Windows builds skip colouring. DWM owns border width and rounding.
- `include`, `exclude`, `float`: arrays of wildcard strings or
  semicolon-separated strings. Case-insensitive whole-value wildcard matching
  (`*`, `?`, character classes), not regular expressions. `exe:` matches
  executable filename/basename, `class:` matches Win32 class, `title:` matches
  title. Unprefixed rules retain the shared app ID/exe/class match. A selector
  that does not compile is ignored and logged by index, never by pattern text.
- `float` is an exclusion alias: matching windows stay unmanaged. Exclude,
  float and disabled-monitor rules win over every inclusion.
- `monitors` maps Qt screen-name wildcard patterns to booleans. All monitors
  default enabled; `false` adds a native `screen:` exclusion, `true` leaves
  the monitor enabled. A blanket false wildcard also excludes true exceptions.
- Live changes keep a running session: the effective rules/gaps/colours are
  diffed against the last applied set and only the changed fields are written
  through the native incremental setters (`gapsIn`, `gapsOut`,
  `singleWindowGapsOut`, `borderColours`, `included`, `excluded`), so explicit
  floats, split ratios and the window tree survive. An identical config is a
  no-op. Only a real switch to Observe/disabled, a config that can no longer
  sustain the session (for example an allowlist that validates to nothing), or
  a backend without the needed setter stops the tiler. Enables still go through
  the existing native mutex gate. A held mutex produces the existing
  `Another tiling manager is already running.` toast. Invalid JSON uses
  Caelestia's ordinary config error handling. Interactive requires a non-empty
  effective include list and is downgraded to Observe during smoke.

The bounded launcher accepts `-TilingConfigFile <shell.json>` and copies only
this section into its isolated profile. Edit the profile's `config/shell.json`
for live reload. `-ProfileRoot` and `-RunRoot` select output paths;
`-BuildRoot` supplies binaries read-only. Existing profile tiling settings
survive another prototype launch.

## Overrides

Explicit launcher switches override environment variables, which override
corresponding profile values. With no override, profile settings apply.

- `CAELESTIA_WINDOWS_TILING=off|observe|interactive`.
  `off` never imports or constructs the backend `Tiling` singleton: the
  facade's `Loader` is bound to the service's `nativeRequested` flag, which
  is false only for `off`. `observe` constructs the wrapper (which runs
  `TilingManager::instance()` and `rescueParked()`), applies `excluded` and
  `included`, and keeps `enabled` false. `interactive` additionally requests
  `enabled = true`, but only when the parsed inclusion list is non-empty AND
  the backend supports `included` (typeof feature detection); otherwise the
  status is `refused` with the reason and the tiler stays disabled. Smoke
  runs force interactive down to observe before anything loads.
- `CAELESTIA_WINDOWS_TILING_INCLUDED`, semicolon-separated wildcards in the
  backend's shared dialect (`title:` prefix selects titles; anything else
  matches app id, executable name/basename and window class). An empty list
  means "all eligible windows" on the backend, which is exactly why
  interactive refuses to enable without one: enabling would immediately lay
  out every eligible window on the desktop. An allowlist whose entries all fail
  the backend's validation (for example an unterminated `[`) is not "empty": it
  matches nothing, and interactive refuses it using the backend's validated
  `includedRuleCount`, not the raw list length. A `title:` selector that would
  match an empty title is rejected the same way.
- `CAELESTIA_WINDOWS_TILING_EXCLUDED`, same dialect, always applied.
  Exclusions win over inclusions; the host process is never managed by the
  backend itself.

`-Tiling -TilingMode Disabled|Observe|Interactive` overrides mode.
`-TilingIncluded` and `-TilingExcluded` override corresponding lists; an explicit
empty string clears the list. Profile float/monitor exclusions still apply.
For direct QML launches, an empty environment value means absent; set the
corresponding variable's `_OVERRIDE=1` companion to explicitly clear it.

The pin includes the M3 allowlist, telemetry and typed exe/class/screen
selectors (`supportsScopedRules`). Older builds refuse Interactive when unable
to enforce inclusion or typed rules. Gap-only Observe runs remain compatible.

`CAELESTIA_WINDOWS_HYPR=1` observation is not required, but with it the
facade resolves each failure's `appClass`/`title` through the Hypr
toplevels; without it the toast says "a window".

## Status

`disabled` (`off`), `observing` (constructed, options applied, `enabled`
false — including interactive still waiting for or denied an enable),
`refused` (interactive blocked by policy, or the backend refused enabling:
`tiler-mutex-held`, `no-screen`), `tiling` (backend `enabled` true). The
facade prints one `CAELESTIA_TILING_STATUS tiling=<mode> included=<n>
excluded=<n> gapsIn=<dip> gapsOut=<dip> status=<status>` line at startup.
`CAELESTIA_TILING_CONFIG` reports each effective config change and
`CAELESTIA_TILING_OPTIONS` reports gaps read back from the backend.

## Fitting-failure explanation

The backend emits `windowTilingFailed(address, reason)` with the address as
lowercase hex without `0x` (matching `HyprlandToplevel`) and one reason of
`min-size`, `off-target`, `correction-limit`, `unresponsive`. The service
records `{address, appClass, title, reason, time}` in a 20-entry list and
decides toasts on the original surface (`Toaster.toast` with `Toast.Warning`
or `Toast.Error`, icon `view_quilt`, copy through `Tr.tr`):

| reason | title | message |
| --- | --- | --- |
| any | `Couldn't tile <App>` (app class, else title, else `a window`) | per reason below |
| `min-size` | | `It needs more space than its tile; it was left floating.` |
| `off-target` | | `It kept moving away from its tile; it was left floating.` |
| `correction-limit` | | `It didn't fit its tile exactly, so it may leave a gap.` |
| `unresponsive` | | `It didn't accept the move, so it was left floating.` |
| unknown | | `It could not be placed in its tile.` |

Rate limits: at most one toast per window address per reason per enabled
session, and at most three toasts per ten seconds. The third toast of a
burst is the summary `Some windows couldn't be tiled`; later failures in
that window are recorded without a toast. Each refused enable attempt emits
exactly one `Tiling is off` error toast: `Add apps to the tiling list to
turn it on.` (empty allowlist), `This version can't limit tiling to chosen
apps.` (backend without `included`), `Another tiling manager is already
running.` or `No screen is available to tile on.`

The allowlist is parsed like the backend does: a `title:` rule with nothing
after the prefix is dropped, so it cannot turn into an empty, unrestricted
backend allowlist.

## Testing

`TilingServiceTest.qml` is an offscreen fixture with fake backends in both
shapes (pinned build without the new members, fork shape with them); it
covers the mode policy, gating refusals, pattern parsing, failure records,
the list cap, every toast copy string, both rate limits, the collapse toast,
enable-refusal toasts and the count/error projection. It also records every
write a fake backend receives, proving that a live gap, border, rule or
identical-config change takes only the incremental setters and never a
stop/disable. It imports no
Quickshell or Caelestia module. Run it through
`windows/scripts/Test-TilingService.ps1`.

`Test-TilingConfig.ps1 -QtPrefix <Qt> -BuildRoot <build>` is a short native
Observe/off smoke. It checks profile-only mode, gap/rule loading, watched
gap/rule changes, and watched disable without ever requesting Interactive.
The backend's `tiling_observability_test` also covers typed exe/class selectors,
disabled-monitor precedence and monitor transfer using fake window facts.
