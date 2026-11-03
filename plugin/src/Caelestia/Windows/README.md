# Windows focus policy

`Caelestia.Windows` is built only on Windows. It provides nonvisual focus,
focus-follows-mouse and font helpers for the isolated compatibility preview:

```qml
import Quickshell.Windows as Native
import Caelestia.Windows

WindowsFocusGuard {
    target: root.contentItem
    foregroundSource: Native.Foreground
    active: drawerNeedsKeyboard
    onOutcome: status => console.log("Windows focus:", status)
    onDismissRequested: closeDrawer()
}
```

`target` is a `QQuickItem*`, normally the native ContentWindow's `contentItem`.
`active` must represent the deliberate keyboard interaction lifetime. Set the
window's keyboard focus to OnDemand while active; the guard does not change
focus flags, drawer state, masks or visibility. Hover-only drawers can leave
it false. The observer crosses the QML boundary as an object property; the
module links no Tiling, Taskbar, Hyprland or backend library.

`available` is constant true in this Windows-only module. `status` contains
the most recent result; `outcome(string)` emits every result. Results also log
under `caelestia.windows.focusguard`; denied native requests are warnings.
`activation-requested` / `restore-requested` mean Windows accepted the request
but the immediate foreground check did not confirm completion. They are not
proof of successful activation.

While inactive, the guard samples the foreground once when it becomes active,
not on a timer. `foregroundSource` is the backend's event-driven
`Quickshell.Windows.Foreground` singleton; it emits
`foregroundChanged(qulonglong hwnd, uint time)` for the same
`EVENT_SYSTEM_FOREGROUND` stream that drives the shell's active window. Opening
samples again before queuing one activation attempt for the next event-loop
turn. The previous sample remains useful if the backend FocusGrab activated the
preview before this binding ran. If another app became foreground after
queuing, activation is skipped. There is no retry when a target is absent,
hidden, no-focus or denied. A target/window replacement starts a new policy
generation.

While active, an external foreground event emits `dismissRequested()` once so
the host can close the drawer. Events older than this activation are ignored by
their tick count, and an event observed while the guard's own window still owns
the foreground is not an outside choice. The host owns dismissal; the guard
never changes drawer state itself.

Closing queues one restore for the next event-loop turn. It proceeds only if
the guard remains inactive, the same target native window is still foreground,
and the saved external HWND is still visible/valid with matching PID and
thread. Outside clicks and Alt-Tab that leave another window foreground prevent
restoration. Reopening, target replacement, window destruction and guard
destruction invalidate any queued work. Destruction never restores focus.

This is a narrow best-effort policy. It installs no global hooks, does not
grab input, holds no polling timer, and uses one ordinary `SetForegroundWindow`
call per attempt. It never uses input-queue attachment, synthetic input or
permission workarounds. HWND/PID/thread matching cannot detect every
same-thread HWND reuse. Win32 has no atomic conditional foreground transfer: a
small race remains between the last ownership check and the native request. It
does not manage owned popups or restore a hidden/destroyed target. Bind at most
one guard to a preview window.

The parent task builds with `windows/scripts/Build-Prototype.ps1` and validates
the native focus behavior. Adding this source does not establish runtime
activation or focus-return compatibility.

`WindowsFocusFollowsMouse` applies `windows.focusFollowsMouse` through
`SystemParametersInfoW` while the shell runs. It reads the current X-Mouse
values before its first write and restores them when disabled or destroyed;
writes never set `SPIF_UPDATEINIFILE`. The `windows/services/focusfollowsmouse`
facade owns the loader and config validation. Its pure controller and
`SystemParametersInfoW` boundary are separate so the unit test can inject a
fake system and never touch the real setting.

## Display power

`WindowsDisplayPower` is a singleton for the explicit panel-off action:

```qml
IpcHandler {
    target: "displays"
    function off(): bool { return WindowsDisplayPower.off(); }
}
```

`off()` queues one `WM_SYSCOMMAND` / `SC_MONITORPOWER = 2` request after 500 ms
and returns true when it was queued. The request is sent with `SendMessage` to a
hidden top-level window owned by the shell process, whose window procedure
forwards to `DefWindowProc`; it is never broadcast. It changes no display path,
topology, resolution, scale or setting. A true result does not prove the panels
went dark. Normal input wakes them, but keep-awake, remote input or background
activity can also wake them.

`windows/scripts/Test-DisplayPower.ps1` runs the fakes-only native test. It
injects a recording sender to prove one send after the delay, and uses a
recording window procedure to inspect the exact `WM_SYSCOMMAND` /
`SC_MONITORPOWER = 2` message without changing real display power. Testing with
a real desktop, including whether Windows retains monitor detection and window
placement, is a separate live QA step.

The module also provides the nonvisual `WindowsFontFallback` singleton.
Windows staging adapts only the original workspace label font binding to
`workspaceFont(Tokens.font.body.small, Tokens.font.workspaces)`. It preserves
the font attributes and returns an explicit ordered family list containing
the configured primary (Rubik by default) and Symbols Nerd Font Mono.
Qt 6.11 exposes only `font.family` in QML; `font.families` is unavailable.
`WindowsFonts.qml` supplies both the symbols font and CaskaydiaCove NF, so the
original mono tokens and builders resolve directly to the patched font.
No global fallback is changed and no fonts are installed into Windows.
