# Windows focus policy

`Caelestia.Windows` is built only on Windows. It provides nonvisual focus and
font helpers for the isolated compatibility preview:

```qml
import Caelestia.Windows

WindowsFocusGuard {
    target: root.contentItem
    active: drawerNeedsKeyboard
    onOutcome: status => console.log("Windows focus:", status)
    onDismissRequested: closeDrawer()
}
```

`target` is a `QQuickItem*`, normally the native ContentWindow's `contentItem`.
`active` must represent the deliberate keyboard interaction lifetime. Set the
window's keyboard focus to OnDemand while active; the guard does not change
focus flags, drawer state, masks or visibility. Hover-only drawers can leave
it false. No Tiling, Taskbar, Hyprland or backend dependency is introduced.

`available` is constant true in this Windows-only module. `status` contains
the most recent result; `outcome(string)` emits every result. Results also log
under `caelestia.windows.focusguard`; denied native requests are warnings.
`activation-requested` / `restore-requested` mean Windows accepted the request
but the immediate foreground check did not confirm completion. They are not
proof of successful activation.

While inactive, a 100 ms timer remembers the last visible external foreground
window with its PID and thread ID. Opening samples again before queuing one
activation attempt for the next event-loop turn. The previous sample remains
useful if the backend FocusGrab activated the preview before this binding ran.
If another app became foreground after queuing, activation is skipped.
There is no retry when a target is absent, hidden, no-focus or denied.
A target/window replacement starts a new policy generation.

While active, the same timer checks for an external foreground window after
550 ms. It emits `dismissRequested()` once so the host can close the drawer
when the backend ignored an early app switch during its 500 ms grace period.
The host owns dismissal; the guard never changes drawer state itself.

Closing queues one restore after 75 ms. It proceeds only if the guard remains
inactive, the same target native window is still foreground, and the saved
external HWND is still visible/valid with matching PID and thread. Outside
clicks and Alt-Tab that leave another window foreground prevent restoration.
Reopening, target replacement, window destruction and guard destruction
invalidate pending work. Destruction never restores focus.

This is a narrow best-effort policy. It installs no global hooks, does not
grab input, and uses one ordinary `SetForegroundWindow` call per attempt.
It never uses input-queue attachment, synthetic input or permission workarounds.
The inactive sample can be up to 100 ms old when another backend already took
focus. HWND/PID/thread matching cannot detect every same-thread HWND reuse.
Polling cannot record every intervening foreground change, and Win32 has no
atomic conditional foreground transfer: a small race remains between the last
ownership check and the native request. It does not manage owned popups or
restore a hidden/destroyed target. Bind at most one guard to a preview window.

The parent task builds with `windows/scripts/Build-Prototype.ps1` and validates
the native focus behavior. Adding this source does not establish runtime
activation or focus-return compatibility.

The module also provides a nonvisual `WindowsFontFallback` element.
`WindowsFonts.qml` constructs it in every staged host to register
`Symbols Nerd Font Mono` as a process-local Qt fallback for
`QChar::Script_Common` (the Nerd private-use glyphs). The same loader supplies
the bundled application fonts. This keeps Rubik as the workspace primary and
preserves every mono token and font builder, without relying on installed
fonts or Windows fallback discovery. No fonts or font settings are installed
into Windows. Constructing this helper performs no native UI or input work.
