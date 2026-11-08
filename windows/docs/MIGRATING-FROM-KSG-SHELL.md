# Migrating from KSG Shell

The importer reads `%APPDATA%\com.ksg.shell\settings.json`. It never changes
KSG Shell, Windows preferences, autostart, running processes or tiler state.
The production Caelestia profile is
`%LOCALAPPDATA%\caelestia-windows\config\shell.json`. The shell installs as a
Windows 11 desktop shell through the versioned `Install-Caelestia.ps1`, with
rollback from Settings > Updates. This script
remains a file converter, not an automatic production-profile integration.

## Preview and write

Run in native Windows PowerShell 5.1 or later from this checkout:

```powershell
# Print merged JSON. No files are written.
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1

# Print a summary containing field names and safe tiling values, not private
# source values, paths, pins or unknown source keys.
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1 -Summary

# Write a separate candidate for review.
$candidate = Join-Path $env:TEMP 'caelestia-shell-candidate.json'
& windows/scripts/Import-KsgShellSettings.ps1 -OutFile $candidate

# Preview replacing an existing candidate, still without writing.
& windows/scripts/Import-KsgShellSettings.ps1 -OutFile $candidate -DryRun
```

`-SettingsFile` selects a different authoritative KSG JSON file.
`-BaseFile` selects an existing Caelestia JSON object to merge. Otherwise,
an existing `-OutFile` is the base, followed by the production config when
present, followed by an empty overlay. Invalid JSON/non-object roots and
conflicting base object/list types fail rather than discard existing data.

Imported preferences win over the base for the mapped fields. Other fields
survive, including unknown future Caelestia fields. Bar lists merge by `id`,
retaining order and unrelated entry properties; absent lists start with the
upstream defaults. Arrays elsewhere are preserved. An enabled KSG bar sets
`bar.persistent=true` but preserves explicit Caelestia screen exclusions.

KSG has no quick-toggle preference. A `utilities.quickToggles` key in the base
replaces the compiled default list, so the importer restores every upstream
default in its compiled order while keeping each existing entry's enabled state
and extra properties, then appends extra ids. The key stays absent when the
base has none, so later default changes still apply.

Any existing output requires `-Force`, even a separate candidate. Forced
replacement creates a sibling
`shell.json.<timestamp>.<unique-id>.bak` containing the original bytes, then
atomically replaces the output. A failed replacement leaves the original
file intact. Output anywhere inside the input KSG profile or the default
KSG roaming profile is rejected even with `-Force`. Do not point output at
the KSG source repository.

`-Summary` changes stdout to the mapping report; combine it with `-DryRun`
when also supplying `-OutFile` to avoid writing. Normal JSON stdout can
contain private values already in the base config. Review locally; use
`-Summary` when sharing results. Unknown KSG values are never copied.

## What imports

The destination schema at this revision is defined by
`plugin/src/Caelestia/Config/`, rather than the older upstream `config/` QML.
The Windows extension is stored at `windows.tiling` and consumed through
`GlobalConfig.windows`. No speculative keybind or wallpaper fields are emitted.

| KSG preference | Caelestia overlay |
| --- | --- |
| `bar.showDate` | `bar.clock.showDate` |
| `bar.enabled=true` | `bar.persistent=true` |
| `bar.enabled=false` | Add `.*` to `bar.excludedScreens` to hide the whole bar |
| `bar.items.tray` | `bar.entries` entry `tray`, `enabled` |
| `bar.items.keyboard` | `bar.statusIcons` entry `kbLayout`, `enabled` |
| `bar.items.bluetooth` | `bar.statusIcons` entry `bluetooth`, `enabled` |
| `bar.items.network` | `bar.statusIcons` entry `network`, `enabled` |
| `bar.items.volume` | `bar.statusIcons` entry `audio`, `enabled` |
| `bar.items.power` | `bar.statusIcons` entry `battery`, `enabled` |
| `osd.enabled` | `osd.enabled` |
| `wm.enabled` | `windows.tiling.enabled`, with `mode="observe"` |
| `wm.gap` | `windows.tiling.gapsIn` |
| `wm.padding` | `windows.tiling.gapsOut` |

Missing or incorrectly typed KSG boolean values use KSG's default `true`;
incorrect types appear in summary warnings. KSG gap/padding defaults are
10 DIPs and clamp to 0..40. The summary preserves fractions; imported gaps
round to the nearest integer DIP because the backend properties are integers.
Existing Caelestia include/exclude/float/monitor rules survive the merge.

Visibility preferences do not establish native backend capability.
For example, importing keyboard/tray visibility does not make unsupported
keyboard observation or tray interception work.

## What requires manual decisions

- **Tiling:** the importer maps enabled/gap/padding into `windows.tiling`,
  always selecting Observe. It never enables either tiler. Environment and
  explicit launcher switches override config. See the
  [tiling service schema](../services/tiling/README.md).
  KSG layout trees, category stacking, floating dimensions, drag behavior
  and resize increments have no equivalent in that adapter.
- **Per-app rules:** KSG's `libs/shell-core/src/wm/rules.rs` opens only its
  eight compiled-in YAML rule sets. There is no persisted user float/tile/
  ignore list in its settings schema and no user YAML is read by that
  implementation. Runtime float overrides are not persisted. The bundled
  first-match rules include regex, executable, class, title, path and
  compound identifiers; M3 offers inclusion/exclusion wildcards with
  exclusion precedence. Bulk translation would change admission semantics.
  Review rules manually: a simple title wildcard can become
  `title:*Example*`; `exe:editor.exe` and `class:ExampleClass` select the
  corresponding fact. Unprefixed patterns retain the shared app ID/exe/class
  dialect. Lists are JSON arrays or semicolon-separated strings. Excluding an app leaves it
  unmanaged; it does not reproduce KSG force, pinning or stack rules.
- **Keybinds:** KSG's `wm/hotkeys.rs` hardcodes Win+P (toggle tiling), Win+F
  (float), Win+M (monocle), Win+Q/Win+Shift+Q (cycle), Alt+I/J/K/L (focus),
  Alt+Shift+I/J/K/L (move), Win+Alt+I/J/K/L (insert), Win+Shift+I/J/K/L/U/O
  (reserve), Win+Alt or Win+Ctrl with +/- (resize), and Win+Alt+0 (reset).
  There is no editable keybind file. The Caelestia drawer shortcut actions
  in `daemons/Shortcuts.qml` are launcher/dashboard/session/sidebar/utilities/
  nexus actions, not these tiler operations, and ConfigRoot has no keybind
  field. No shortcut is silently reassigned to a different action.
- **Wallpaper:** KSG has no wallpaper path in its settings schema.
  The wallpaper belongs to Windows. A fresh Caelestia profile starts on the
  bundled Caelestia asset; choosing a wallpaper through Caelestia writes it to
  Windows and records the choice. A profile that already has a generated
  palette source keeps the Windows wallpaper it showed before the upgrade.
  Switching shells does not require copying the image into a config field.
  `paths.wallpaperDir` is a collection directory, not the current image.
- **Theme/accent:** KSG reads Windows appearance and accent live through
  `appearance.rs`; these are not per-user KSG overrides. Caelestia's fixed
  palette/dynamic-scheme integration is separate. No Windows personalization
  setting is changed or claimed to be imported.
- **Monitors:** `DockSettings.enabledMonitors` exists as an in-memory host
  policy, but native `settings.rs::parse` does not populate it from the
  settings file. KSG stable display IDs also differ from Qt screen names.
  Set `windows.tiling.monitors` using Qt screen names or wildcards after review.
- **Notifications/dock/takeover:** `bar.items.notifications` hides a KSG
  icon. Caelestia's `sidebar.enabled` disables the drawer itself, which is
  different. The dock's enable/size/magnification preferences and
  `data/dock/state.yml` pins have no corresponding Caelestia dock/pins schema.
  `shell.startAtSignIn`, `hideTaskbar` and `notificationArea` govern shell
  ownership, so they require separate explicit takeover/autostart choices.
  The importer does not read pin launch commands or alter registrations.
- **Other profile files:** `settings.json.pre-m6` and pin backups are
  historical copies, not active preferences. They are not merged.
  Unknown JSON keys are retained by KSG but are not necessarily effective
  settings; the importer does not treat them as undocumented features.

Source audit: KSG revision `85bd3d852d03111ac4e78d77e46a513969754018`,
especially `settings.rs`, `paths.rs`, `model.rs`, `appearance.rs`, `wm/mod.rs`,
`wm/rules.rs` and `wm/hotkeys.rs` under `libs/shell-core/src/`.
M3 reference revision: `5777a2464619229e2fb36c7ade3696505f4a16a6`.
Recheck these contracts before adding mappings after either schema evolves.

## Switch-over

1. Preview the import and keep a reviewed candidate. Keep KSG's settings and
   existing install intact. Start with Caelestia tiling **off**. In particular,
   do not treat KSG's saved `wm.enabled=true` as permission to enable M3.
2. In KSG's own Settings, set window tiling off (`wm.enabled=false`) and
   confirm it is off. Its launch flags can override the saved value: a KSG
   process started with `--tiling` must be exited before proceeding if the
   setting is overridden. Never run two active tilers. This is a manual
   switch-over step, not an action performed by this script.
3. Exit KSG through its normal exit path before full shell takeover, to
   release its bar/taskbar/tray ownership as well as its tiler. Preserve
   other applications. Confirm KSG has exited. Keep its autostart entry
   disabled during the trial using its supported UI if necessary.
4. Once the production launcher/profile is integrated, install the reviewed
   overlay explicitly:

   ```powershell
   $config = Join-Path $env:LOCALAPPDATA 'caelestia-windows\config\shell.json'
   & windows/scripts/Import-KsgShellSettings.ps1 -OutFile $config -DryRun
   # After reviewing, write it; -Force also backs up an existing config.
   & windows/scripts/Import-KsgShellSettings.ps1 -OutFile $config -Force
   ```

5. Launch the integrated production shell using its documented launcher,
   with tiling off and takeover/autostart enabled only when explicitly chosen.
   For an isolated trial, choose a separate prefix and profile in the
   [production installer](../shell/README.md#install-and-run), and place the
   reviewed configuration in that profile.
6. Test the bar and services first. For the separately integrated M3 adapter,
   choose a small non-empty inclusion list and review exclusions before
   selecting `windows.tiling.mode="interactive"`. `observe` constructs the native controller
   and may rescue previously parked windows even though it keeps tiling
   disabled; it is not a zero-effect dry run. The pinned M3 reference runtime
   supports inclusion and typed app/monitor selectors. Older builds refuse
   interactive when they cannot enforce the configured selectors.
7. Validate window placement, monitors, fullscreen, minimum-size handling,
   sleep/wake and exit restoration before choosing Caelestia autostart.

## Go back

Set Caelestia tiling off and exit Caelestia normally. Confirm its process has
exited and its tiler/desktop ownership is released before restarting KSG.
Restore the Caelestia config from its `.bak` if desired while Caelestia is
stopped. Restart KSG from its existing installation; restore its previous
autostart choice and enable its tiler in KSG Settings only after Caelestia's
tiler is gone. Remove any temporary KSG `--no-tiling` launch override if used.
No KSG backup restoration is needed for the import itself: it never writes
KSG's profile.

Use the importer's `-Summary` mode to review the proposed mapping without
writing configuration. Keep the backup until normal-use migration is accepted.
