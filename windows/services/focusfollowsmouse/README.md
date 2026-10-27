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
| `plugin/src/Caelestia/Windows/Focus/focusfollowsmouse.{hpp,cpp}` | Pure controller: captures the current values, writes only changed fields, restores on disable/destruction; injectable system boundary |
| `plugin/src/Caelestia/Windows/Focus/windowsfocusfollowsmouse.{hpp,cpp}` | `Caelestia.Windows.WindowsFocusFollowsMouse` QML element over `SystemParametersInfoW` |
| `FocusFollowsMouse.qml` | Watched `qs.services` facade staged as `services/FocusFollowsMouse.qml` |
| `NativeFocusFollowsMouse.qml` | Loader-only wrapper, active only while the option is enabled |

## Behaviour

- `enabled`: apply `SPI_SETACTIVEWINDOWTRACKING`, `SPI_SETACTIVEWNDTRKTIMEOUT`
  and `SPI_SETACTIVEWNDTRKZORDER` while the shell runs. Default `false`.
- `delay`: tracking timeout in milliseconds, clamped to 0-5000. Default `100`.
- `raise`: bring the focused window to the top. Default `false`.

The controller reads all three system values immediately before its first
write. Re-applying after a live config change writes only fields that differ,
so the original values stay saved. Disabling the option, unloading the loader,
or destroying the native object restores exactly the fields that were changed.
If the option is disabled at startup, the native object is not constructed and
no system value is read or written.

## Crash safety

Writes pass no `SPIF_UPDATEINIFILE`, so the user's stored X-Mouse preference is
never changed. A crash or forced kill can leave the live session tracking until
sign-out, but the next logon restores the stored value. The supervisor is not
changed: it restarts the shell after a crash (which re-applies the option), and
restoring from the supervisor would need a separate saved-state channel and
could fight a user's own Windows setting. A clean shell exit restores through
the native destructor.

## Testing

`plugin/src/Caelestia/Windows/Focus/test/focusfollowsmouse_test.cpp` uses a fake
system boundary and never touches the real Windows setting. It covers the
disabled no-op, capture/restore, changed-field-only writes, live re-apply,
clamping, read failure, partial-failure rollback, destructor restore and
idempotent restore. Build target: `focus-follows-mouse-tests`.
