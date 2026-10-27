# Windows focus-follows-mouse service

`windows.focusFollowsMouse` in `shell.json` owns Windows' X-Mouse focus
tracking while the shell runs. The option is off by default, so the
Windows-level setting is left alone.

```json
{
  "windows": {
    "focusFollowsMouse": {
      "enabled": true,
      "delay": 100,
      "raise": false
    }
  }
}
```

| file | role |
| --- | --- |
| `plugin/src/Caelestia/Windows/Focus/focusfollowsmouse.{hpp,cpp}` | Controller plus process-wide owner: one baseline and one live-controller list, write-only-changed fields, restore on the last release; injectable system boundary and recovery file |
| `plugin/src/Caelestia/Windows/Focus/windowsfocusfollowsmouse.{hpp,cpp}` | `Caelestia.Windows.WindowsFocusFollowsMouse` QML element over `SystemParametersInfoW` |
| `FocusFollowsMouse.qml` | Watched `qs.services` facade staged as `services/FocusFollowsMouse.qml` |
| `NativeFocusFollowsMouse.qml` | Loader-only wrapper, active only while the option is enabled; passes `CAELESTIA_RUNTIME_DIR` to the native object |

## Behaviour

- `enabled`: apply `SPI_SETACTIVEWINDOWTRACKING`, `SPI_SETACTIVEWNDTRKTIMEOUT`
  and `SPI_SETACTIVEWNDTRKZORDER` while the shell runs. Default `false`.
- `delay`: tracking timeout in milliseconds, clamped to 0-5000. Default `100`.
- `raise`: bring the focused window to the top. Default `false`.

The process-wide owner reads all three system values once, immediately before
the first write, and keeps that baseline. Re-applying after a live config
change writes only fields that differ, so the original values stay saved.
Quickshell creates a reload's replacement QML generation before destroying the
old one: both generations' controllers share the same owner, so the replacement
reuses the baseline and re-applies its own desired values, and the old
generation's destruction does not restore while the replacement is live. The
most recently created or updated controller's values win. Disabling the option,
unloading the loader, or destroying the last live controller restores exactly
the fields that were changed.

If the option is disabled at startup, the native object is not constructed and
no system value is read or written.

## Crash safety

Writes pass no `SPIF_UPDATEINIFILE`, so the user's stored X-Mouse preference is
never changed. Before the first write the controller saves the baseline to
`focus-follows-mouse-recovery.json` in the profile's `runtime` directory
(`CAELESTIA_RUNTIME_DIR`, normally `%LOCALAPPDATA%\caelestia-windows\runtime`).
The write is atomic (temp file plus rename). A crash or forced kill leaves that
file behind; after the supervisor restarts the shell, the new process uses the
file's baseline instead of treating the still-applied session values as the
original, so disabling the option or a later clean exit restores the user's
values instead of leaving tracking on. The file is deleted after a successful
restore. A clean shell exit restores through `aboutToQuit` and the native
destructor.

## Testing

`plugin/src/Caelestia/Windows/Focus/test/focusfollowsmouse_test.cpp` uses a fake
system boundary and a temporary recovery-file directory, so it never touches
the real Windows setting. It covers the disabled no-op, capture/restore,
changed-field-only writes, live re-apply, clamping, read failure,
partial-failure rollback, destructor restore, idempotent restore, overlapping
generations, most-recent-update wins, recovery-file baseline and removal, and
no file write while disabled. Build target: `focus-follows-mouse-tests`; run it
with `windows/scripts/Test-FocusFollowsMouse.ps1`.
