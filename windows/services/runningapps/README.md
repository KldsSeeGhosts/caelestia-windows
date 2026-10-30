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
- Close is a normal native close request, not process termination. The model
  retains the window until it actually closes, including while a save prompt is
  open.
- Hover only shows descriptive tooltips. Escape or an outside click dismisses
  the chooser.
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
high-resolution pixel-delta input is not separately synthesized offscreen. Use
the undeployed build executable with its matching full Qt development prefix
and artifact QML plugins. A deployed Windows-only runtime is not an offscreen
runner. The harness checks versions and metadata, resets native control gates
before starting Qt, and retains both output streams on failure or timeout. Qt
environment values are process-local, not QML environment pragmas. The preflight
opens no windows; the fixture additionally instantiates and dismisses the
multi-window chooser offscreen.

Real focus, popup dismissal, icon extraction, multi-desktop activation, and save
prompts require a separate native QA pass. No native backend pin change is needed.
