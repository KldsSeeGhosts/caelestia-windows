# Live fixes 1: frame exclusions and keyboard status

Validated shell `28a9b7882c9488ccbaee769291b97cd21cd3c561`, backend
`b5d60be7b600cb22045db8b72b62ed34d44079c2`, Qt 6.11.2, clang-cl 20.1.8,
Windows build 26300. Source pins and tools match in `build/environment.json`.
The shell source was clean for the final runs. This is targeted compatibility
evidence, not full shell release acceptance.

## Implementation

Upstream `modules/drawers/Exclusions.qml` has four exclusion windows. The
Windows combined adapter had reduced this to one left AppBar. The adapter now
retains one AppBar per edge: the bar zone on the left, per-screen configured
border thickness on top/right/bottom. Both installed and combined entries bind
their visibility to the original `ContentWindow.hasFullscreen` state. Native
AppBar registration, normal removal, registry ownership and production watchdog
recovery are unchanged.

The Windows Hypr facade reads the native Keyboard singleton behind its
observation opt-in. Its existing foreground-thread `GetKeyboardLayout` observer
now polls continuously at 500 ms, also reading Caps Lock/Num Lock toggle bits
with `GetKeyState`. `kbLayout` uses the locale's short language code, `en` here.
No input language or keyboard state was changed by these tests.

Temporary installed smoke runs directly with an owned child, bypassing the
session-wide desktop supervisor mutex. Cleanup removes only that exited child's
stale AppBars and never invokes global recovery/taskbar restoration.
`-Smoke -ScreenIndex 1` confines drawers, background hosts and reservations to
the selected secondary display.

## Build and commands

The backend was built in this checkout's `windows/.local/build/quickshell`,
from the authorized backend worktree
`D:\AiStack\caelestia-windows\windows\.local\qs-livefix`.
`build/build-backend-command.ps1` records the complete native CMake commands.
`build/build-backend.log` records the final successful configure/build.
Unchanged portable plugins were copied from the read-only supplied build:
`C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-9957da37\windows\.local\build`.
`build/build.json` records that provenance.

From the shell checkout:

```powershell
$qt = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 `
    -QtPrefix $qt -QuickshellExecutable "$PWD\windows\.local\build\quickshell\qs.exe" -Json
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qt -Combined -Smoke
powershell -NoProfile -File windows/scripts/Test-InstalledFrame.ps1 `
    -QtPrefix $qt -ScreenIndex 1 `
    -OutputRoot windows/.local/frame-acceptance-serial
```

## Observations

- Combined native 150% smoke passes all existing phases and the new assertion
  that the original status entry renders the native short code. See
  `combined/keyboard-layout.png`, with `en` in the left status column, and
  `CAELESTIA_COMBINED_KEYBOARD en` in `combined/stdout.log`.
- Temporary deployed-runtime smoke passes at native 175% on DELL S2725QS,
  `\\.\DISPLAY2`. Native logs show four distinct HWNDs on edges 0/1/2/3.
- `GetMonitorInfo` physical work area on the secondary display changes from
  `(-3735,0)-(0,2160)` to `(-3630,18)-(-18,2142)`: left +105 physical pixels
  (60 DIP at 1.75), top/right/bottom +18 (10 DIP rounded at 1.75).
- The primary work area stays `(90,0)-(3840,2160)`. Both monitors return
  exactly to their starting work areas after quit. Taskbar flags and the
  pre-existing installed shell PID 33252 are preserved.
- The real exclusion component's isolated fixture releases all four test
  AppBars when its fullscreen input is set, and reacquires them when cleared.
  The fixture never creates a fullscreen application, so the live shell's
  reservations remain intact. See `frame/fixture-*.json`.
- Runtime stderr is empty. Installer translation-catalog and CMake path-length
  warnings are retained in their logs; neither prevented build/deployment.

Earlier exploratory runs exposed two harness bookkeeping errors (PID field and
PowerShell process-handle retention), both corrected. An overlapping acceptance
attempt was rejected because a separately owned combined smoke naturally exited
before the preservation check. The final serial run is the accepted record.

Real application fullscreen transitions, forced-crash/watchdog recovery,
language switching, lock-key input, monitor hotplug and DPI transfer were not
exercised while the user's shell was live. The existing fullscreen detection and
production recovery paths remain in use. No default installation, user profile,
taskbar visibility or user-owned process was modified.

`result.json` and `matrix.json` index the accepted artifacts. Per-run result
paths retain their original local destinations; the archived logs and capture
are alongside this README. Staged QML and per-run source manifests are omitted.
