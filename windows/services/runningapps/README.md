# Running applications

The combined Windows graph adds a running-app pill below the original workspace
switcher. The active-window title and live preview remain unchanged. Linux and
the bounded M1 graph do not load this feature.

The pill shows one icon per application with tracked top-level windows, including
minimized windows and windows on other desktops. Every monitor can reach the same
list. Tray-only/background applications stay in the existing tray.

- Left-click a single-window app to restore/focus it. Clicking an already focused
  app does not minimize it.
- Left-click a multi-window app to choose a window by title and desktop.
- Right-click any app for its window chooser, including Minimize and Close.
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
- Hover only shows descriptive tooltips. Escape dismisses the chooser from the
  window list and from every Tab-focused row action. An outside click dismisses
  it too: the native popup requests the platform close, backed by a parent-window
  click-away layer so the same interaction is deterministic offscreen. A chooser
  opened for a new gesture starts on the first window, and Return clamps a
  selection left stale by a shrinking window list.
- The viewport reserves one to five complete icon rows according to available
  bar space. Additional apps scroll inside it. A short list still consumes wheel
  input without moving, so it cannot trigger the workspace, volume, or
  brightness shortcuts. Wheel input outside the pill keeps those bar shortcuts.
- First-seen app/window ordering follows source encounter order, never numeric
  id, title, focus or MRU order. Minimize, focus, title, duplicate-handle and
  desktop updates do not reorder entries. A temporarily app-cloaked window
  keeps its slot and returns to it when uncloaked; a window that actually
  closes releases its slot, and a later recreation is appended. Nothing is
  pinned or persisted.

`RunningAppsModel.qml` projects injected observations. `RunningApps.qml` shares
the existing opted-in Hypr facade and requires its existing dispatch gate for
controls. Read-only smoke cannot activate, minimize, or close native windows.
The pure grouping logic has no process enumeration or launching.

The pinned backend's `activated` observation is its tracked foreground
application, derived from `GetForegroundWindow()`; it is not a direct foreground
query from QML. Shell overlay windows deliberately preserve the last application
there, so the gate is an observable proxy, not proof of Win32 foreground. An
other-desktop window is DWM-cloaked, and the tracker clears the active
observation when the foreground is not shown; minimized state is observed
separately. The close timer also waits for that minimized observation because
the backend restores with `ShowWindowAsync` and can defer foreground activation
by 400 ms after a virtual-desktop switch. The chooser is dismissed before the
request, and a timeout cancels rather than posting an unobserved `WM_CLOSE`.

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

The QML check uses an offscreen disposable profile and fake native handles.
It mounts the bar inside a window-sized Interactions-style MouseArea like
ContentWindow, loads the bundled Material Symbols font, and sends synthetic
wheel events for an overflowing list, a short list, and the workspace area.
The overflowing list scrolls through the Flickable, the short list is consumed
by the pill's WheelHandler, and only wheel input outside the pill reaches the
bar's existing workspace shortcut. QtTest synthesizes angle-delta wheel events;
high-resolution pixel-delta input is not separately synthesized offscreen. The
same fixture defers fake activation to prove zero early closes and exactly one
after confirmation. It then covers bounded timeout, disappearance, reused ids,
disabled controls and a destroyed native handle, drives two concurrent close
requests through serialized activation, and simulates a cancelled save prompt:
the first close leaves the window open, a duplicate inside the coalescing window
is ignored, and a deliberate retry posts exactly one more close.

The interaction pass opens the chooser with a real synthetic left click on the
pill row, then sends Escape from the list and from Tab-focused row actions. It
checks the Tab order through a row's activate, minimize and close actions, then
into the next row, reopens after an earlier selection and confirms the selection
resets, and shrinks the window list immediately before Return to exercise the
stale-index clamp.
A real synthetic click on the parent window outside the popup exercises the
click-away layer. All of these checks drive Qt input events; they do not call
the chooser's open/close methods or assign `visible` directly.

Use the undeployed build executable with its matching full Qt development prefix
and artifact QML plugins. A deployed Windows-only runtime is not an offscreen
runner. The harness checks versions and metadata, resets native control gates
before starting Qt, and retains both output streams on failure or timeout. Qt
environment values are process-local, not QML environment pragmas. The preflight
opens no windows; the fixture additionally instantiates, traverses and dismisses
the multi-window chooser offscreen.

The harness records `sourceMatchesBuild` from the build metadata and the current
checkout. This is provenance, not a pass gate: QML is staged from the checkout,
so a QML-only change can run against a native artifact built from an earlier
revision. A true value means the native artifact and both native submodules were
built from this exact clean revision; false does not by itself mean the QML
under test is stale.

Real pointer and focus delivery to the native popup, icon extraction,
multi-desktop activation, and save prompts require a separate native QA pass.
The offscreen parent-window click-away path proves dismissal behavior, not
Windows' native Qt::Popup click routing. No native backend pin change is needed.
