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
  bar space. Additional apps scroll inside it. Wheel events cannot reach the
  surrounding workspace, volume, or brightness shortcuts.
- First-seen app/window ordering is stable for the lifetime of those windows.
  Nothing is pinned or persisted.

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
Use the undeployed build executable with its matching full Qt development
prefix and artifact QML plugins. A deployed Windows-only runtime is not an
offscreen runner. The harness checks versions and metadata, resets native
control gates before starting Qt, and retains both output streams on failure
or timeout. Qt environment values are process-local, not QML environment
pragmas. The preflight opens no windows; the fixture additionally instantiates
and dismisses the multi-window chooser offscreen.

Real focus, popup dismissal, icon extraction, multi-desktop activation, and save
prompts require a separate native QA pass. No native backend pin change is needed.
