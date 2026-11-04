# Running applications

The combined Windows graph makes the original bar's active-window entry the
running-application strip. One icon stands for each application with tracked
top-level windows, including minimized windows and windows on other desktops.
Every monitor can reach the same list. Tray-only/background applications stay
in the existing tray. The strip disappears when no application is running.

- The strip fits whole 32 px rows into the space the other bar entries leave.
  Past that budget it scrolls with its 2 px scrollbar, and Tab focus scrolls
  the focused row into view. Wheel input is always consumed, even when the list
  does not overflow, so it never reaches the workspace, volume or brightness
  shortcuts.
- `m3surfaceContainer` capsule, `rounding.full`, and one `m3secondaryContainer`
  circle behind the application that owns the native foreground. The circle
  slides with the expressive spatial curve and fades out while no listed
  application is in the foreground. Minimized applications look exactly like
  running ones; there is no badge, outline or dimmed state.
- Left-click follows Windows 11: an application that is not focused (or whose
  windows are all minimized) focuses its last-active window, restoring it if it
  is minimized; a focused single-window application minimizes; a focused
  multi-window application cycles to its next window in stable order. Focus
  comes from the native foreground window (the backend's WinEvent foreground
  stream), never from the facade's `activated` value, which is retained while
  the shell itself holds the foreground. No process is terminated.
- Hovering a row opens the original active-window popout on that row's centre.
  The popout shows one row per window of that application, with the title and a
  close (✕) button; clicking a row activates that window, hovering a row swaps
  the preview, and Return activates the keyboard-current row. The close button
  uses the guarded close path below. Only the selected window is captured: a
  minimized or uncapturable window shows its icon, its title and "Minimized"
  (or "No preview") instead, and is never restored just to preview it.
- Escape and outside dismissal follow the existing popout wrapper. Right-click
  opens the same popout without waiting for a hover and stops following the
  pointer until it closes, for keyboard and touch users. Middle-click does
  nothing; launching a new instance is a follow-up because the service cannot
  launch applications yet.
- Close first requests restore/activation and waits for the backend to observe
  the target as both active and not minimized, then posts one native close
  request. Close requests are serialized: only the head may change foreground,
  and the next request starts after the head dispatches, cancels or times out,
  so concurrent requests do not steal each other's activation. A bounded
  timeout, target disappearance or replacement, or disabled controls cancels
  the request. A dispatched close coalesces duplicates for a short bounded
  window, so one request posts at most one native close, while a user who
  cancels a save prompt can deliberately retry after that window. The model
  retains the window until it actually closes, including while a save prompt is
  open.
- First-seen app/window ordering follows source encounter order, never numeric
  id, title, focus or MRU order. Minimize, focus, title, duplicate-handle and
  desktop updates do not reorder entries. A temporarily app-cloaked window
  keeps its slot and returns to it when uncloaked; a window that actually
  closes releases its slot, and a later recreation is appended. Nothing is
  pinned or persisted.

`RunningAppsModel.qml` projects injected observations. `RunningApps.qml` shares
the existing opted-in Hypr facade and requires its existing dispatch gate for
controls, and turns the backend's raw `Foreground.foregroundChanged` handle into
the native foreground address. Read-only smoke cannot activate, minimize, or
close native windows. The pure grouping and click logic has no process
enumeration or launching.

The pinned backend's `activated` observation is its tracked foreground
application, derived from `GetForegroundWindow()`; it is not a direct foreground
query from QML. Shell overlay windows deliberately preserve the last application
there, so the facade gate is an observable proxy, not proof of Win32 foreground.
That is why the strip reads `Foreground.foregroundChanged`, which reports the raw
handle for every foreground change (including the shell's own surfaces) and is
empty while a shell surface owns focus. An other-desktop window is
DWM-cloaked, and the tracker clears the active observation when the foreground
is not shown; minimized state is observed separately. The close timer also waits
for that minimized observation because the backend restores with
`ShowWindowAsync` and can defer foreground activation by 400 ms after a
virtual-desktop switch.

Only the head of the pending close queue calls `activate()`. This prevents two
close requests from racing for foreground and making the earlier request time
out, but it does not prove that a save prompt was resolved: activating the next
request can still move foreground away from an earlier prompt. The model only
bounds duplicate `WM_CLOSE` dispatches; it cannot observe the prompt outcome.
After a dispatch, duplicate requests are ignored for `closeCoalesceMs` (1 s),
and a target that is still open can then be closed again deliberately. A target
that times out before dispatch leaves no coalescing entry, so an immediate retry
is allowed.

Focused checks:

```powershell
node windows/tests/RunningApps.test.js
windows/scripts/Test-RunningApps.ps1 -Preflight -QtPrefix <Qt-prefix> -BuildRoot <build> -ExpectedRuntimeHash <sha256>
windows/scripts/Test-RunningApps.ps1 -QtPrefix <Qt-prefix> -BuildRoot <build>
```

The QML check uses an offscreen disposable profile and fake native handles. It
mounts the bar inside a window-sized Interactions-style mouse area like
ContentWindow, so the shared popout opens through the bar's real hover edge.
It covers the strip's grouping, whole-row budgeting, overflow scroll and the
always-consumed wheel with an overflowing list, a short list and the workspace
area. It then drives real clicks on the strip: an unfocused application focuses
its last-active window, a retained facade `activated` value is not native
foreground, a focused single-window application minimizes, and a focused
multi-window application cycles and wraps in stable order. It hovers the strip
to open the popout at the row's centre, checks the row count, swaps the preview
from a row hover, activates from a row click, pins the popout with a
right-click, and closes a window through the row's guarded ✕ path. Finally it
checks that the empty strip is hidden. QtTest synthesizes angle-delta wheel
events; high-resolution pixel-delta input is not separately synthesized
offscreen. The same fixture keeps the existing close-queue coverage: deferred
activation, bounded timeout, disappearance, reused ids, disabled controls, a
destroyed native handle, two concurrent close requests, and a cancelled save
prompt with a coalesced duplicate and a deliberate retry. It also checks that
only the head of the close queue may change foreground.

Use the undeployed build executable with its matching full Qt development prefix
and artifact QML plugins. A deployed Windows-only runtime is not an offscreen
runner. The harness checks versions and metadata, resets native control gates
before starting Qt, and retains both output streams on failure or timeout. Qt
environment values are process-local, not QML environment pragmas. The preflight
opens no windows.

The harness records `sourceMatchesBuild` from the build metadata and the current
checkout. This is provenance, not a pass gate: QML is staged from the checkout,
so a QML-only change can run against a native artifact built from an earlier
revision. A true value means the native artifact and both native submodules were
built from this exact clean revision; false does not by itself mean the QML
under test is stale.

Real pointer and focus delivery, icon extraction, multi-desktop activation, and
save prompts require a separate native QA pass. The offscreen parent-window
dismissal path proves dismissal behavior, not Windows' native popup click
routing. No native backend pin change is needed.
