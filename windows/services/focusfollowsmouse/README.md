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
never changed. Before the first write the controller saves the baseline and the
values it applies to `focus-follows-mouse-recovery.json` in the profile's
`runtime` directory (`CAELESTIA_RUNTIME_DIR`, normally
`%LOCALAPPDATA%\caelestia-windows\runtime`). The write is atomic (temp file plus
rename). A live delay or raise change rewrites the file, so it always records
the session's current applied values.

A crash or forced kill leaves that file behind; after the supervisor restarts
the shell, the new process uses the file's baseline only while the system still
holds the recorded applied values. If the user changed the Windows X-Mouse
setting while the shell was down, the file is discarded, the live values become
the new baseline, and a later clean exit restores the user's change instead of
the stale values. A file without applied values (written by an older build)
cannot be validated and is also discarded. The file is deleted after a
successful restore. A clean shell exit restores through `aboutToQuit` and the
native destructor.

## Validation

The [public production smoke](../../NATIVE-BUILD.md#smoke) keeps this feature
disabled and does not change Windows' X-Mouse setting. A live check requires
explicit opt-in: record the original settings, verify focus behavior and live
configuration changes, then disable and confirm exact restoration. Recovery
must not overwrite a subsequent user change. Keep recovery records until
restoration has been confirmed.
