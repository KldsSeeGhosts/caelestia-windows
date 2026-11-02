# Native Windows build and prototypes

The first verified build uses Windows 11, Qt 6.11.2 `msvc2022_64`, clang-cl
20.1.8, Visual Studio Build Tools 2022, Windows SDK 10.0.26100.0, CMake 4.4.4,
Ninja 1.13.2, and CLI11 2.5.0. The main entry point is now the
[bounded native bar/session prototype](shell-prototype/README.md); the earlier
component probe is retained. A build or smoke pass does not complete M1.
The separate [final acceptance record](validation/2026-10-25-m1-acceptance/README.md)
now completes the bounded M1 gate with native input and lifecycle evidence.

## Developer dependencies

Visual Studio Build Tools must already include the x64 C++ tools and Windows
SDK. The build script discovers them with `vswhere.exe` and enters their
environment in its own process. No machine PATH or Visual Studio installation
is changed by the build script.

The following setup commands download development tools into a separate
per-user directory. Run them in native Windows PowerShell. Python 3.12, Git,
`curl.exe`, and `tar.exe` were available on the initial workstation.

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
New-Item -ItemType Directory -Force -Path $devRoot | Out-Null
py -m venv "$devRoot\tools"
$python = "$devRoot\tools\Scripts\python.exe"
& $python -m pip install cmake==4.4.4 ninja==1.13.2 `
    'https://github.com/miurahr/aqtinstall/archive/076e1659807d0b362a3ed684d54c2e9c775eb9c7.zip'
```

The aqtinstall revision is intentional: released 3.3.0 does not support this
Qt repository layout. The archive list below deliberately omits the separate
`qttranslations` component, because the installer ships no Qt translation
catalogs and the shell installs no `QTranslator`. As a result `windeployqt`
prints `Translations will not be available ... translations/catalogs.json`
even with `--no-translations`. That message is informational and does not
prevent deployment. Keep its log outside the source checkout:

```powershell
Push-Location $devRoot
try {
    & $python -m aqt install-qt windows desktop 6.11.2 win64_msvc2022_64 `
        -O "$devRoot\Qt" --modules qtshadertools qtimageformats `
        --archives qtbase qtdeclarative qtsvg qttools
} finally {
    Pop-Location
}
```

Download the LLVM archive from its
[official release](https://github.com/llvm/llvm-project/releases/tag/llvmorg-20.1.8).
The SHA-256 below matches the release asset digest.

```powershell
$llvmArchive = "$devRoot\llvm-20.1.8.tar.xz"
curl.exe -L --fail --silent --show-error `
    'https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.8/clang+llvm-20.1.8-x86_64-pc-windows-msvc.tar.xz' `
    -o $llvmArchive
if ($LASTEXITCODE -ne 0) { throw 'LLVM download failed.' }
$expected = 'f229769f11d6a6edc8ada599c0cda964b7dee6ab1a08c6cf9dd7f513e85b107f'
if ((Get-FileHash -LiteralPath $llvmArchive).Hash -ne $expected) {
    throw 'LLVM checksum mismatch.'
}
tar.exe -xf $llvmArchive -C $devRoot
if ($LASTEXITCODE -ne 0) { throw 'LLVM extraction failed.' }

curl.exe -L --fail --silent --show-error `
    'https://github.com/CLIUtils/CLI11/archive/refs/tags/v2.5.0.zip' `
    -o "$devRoot\cli11.zip"
if ($LASTEXITCODE -ne 0) { throw 'CLI11 download failed.' }
$cli11Expected = '887270cae374a0b9e22b39647f9fc4bc742587fb26d6a221da2d2bbcf3109b0b'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath "$devRoot\cli11.zip").Hash -ne $cli11Expected) {
    Remove-Item -LiteralPath "$devRoot\cli11.zip" -Force
    throw 'CLI11 checksum mismatch.'
}
Expand-Archive -LiteralPath "$devRoot\cli11.zip" -DestinationPath "$devRoot\deps" -Force
```

## Build

From the repository root:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
```

`-BuildRoot` selects another output directory and `-Jobs` changes parallelism
(default 4). The default directory is `windows/.local/build`. `-Tests` also
builds the native test executables used by
`windows/scripts/Test-ClipboardHistory.ps1`, `Test-DisplayPower.ps1` and
`Test-FocusFollowsMouse.ps1`; production builds omit them.

The build also produces `quickshell/brightness-probe.exe`. It uses the native
brightness controller without starting the shell. Set Qt's bin directory in
the current PowerShell process before using it:

```powershell
$env:PATH = "$devRoot\Qt\6.11.2\msvc2022_64\bin;$env:PATH"
$probe = "$PWD\windows\.local\build\quickshell\brightness-probe.exe"
& $probe
& $probe -Display 'MAG321UX OLED' -Set 40
& $probe -Display 'MAG321UX OLED' -Restore
```

The first command is read-only. Set and Restore change the selected HDR
display's SDR white level. The probe records the exact original raw value in
`%TEMP%\caelestia-brightness-sdr-white-journal.json` before its first set,
keyed by monitor device path, and removes that entry only after an exact
read-back on restore. Restore requires the same active display path and HDR
mode. Back up the journal if needed; do not delete it before restoration.
The Windows set request is undocumented and may fail or change on future
Windows versions. Read-back confirms the reported setting, not physical
display luminance. No physical write or HDR-toggle acceptance is implied by
the build or fixtures.

The script:

1. Runs `Test-Environment.ps1 -Json -Strict` in the development environment and
   checks that the backend and M3Shapes worktrees are clean and match the source
   manifest.
2. Builds the pinned backend's `qs.exe` with crash handling and backend tests
   disabled. This does not execute the shell or enable autostart.
3. Builds the pinned external `windows/deps/m3shapes` plugin and installs the
   `M3Shapes` QML module (its `m3shapes.dll`, plugin DLL, `qmldir` and type
   information) into the build directory's `install/qml`.
4. Builds Caelestia with `CAELESTIA_PORTABLE_UI=ON` and `ENABLE_MODULES=plugin`.
5. Installs the eight portable modules and Windows-only `Caelestia.Windows`
   module into the build directory's `install/qml`. The latter supplies
   WindowsFocusGuard for the native prototype.
6. Records command arguments, logs, source revisions (including M3Shapes), and
   tool versions under `logs/`. No packages are published.

## Smoke

The public smoke command is:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Test-Smoke.ps1 `
    -BuildRoot C:\b-smoke `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64"
```

It stages the production map in `windows/shell/sources.json` exactly as the
installer does (`Stage-ShellPrototype.ps1 -Prototype shell-live`), starts the
built `quickshell/qs.exe` against an isolated temporary profile, and waits for
every drawer's first frame. The process uses `QT_QPA_PLATFORM=offscreen` and
the Qt Quick software backend. Tray hook, blur, tiling, background/desktop
embedding, notification mirroring, hotkeys, Wallpaper Engine and every service
control are off; an empty keybind list and `CAELESTIA_SHELL_SMOKE_CI` let the
shell exit itself. The script also checks the build's backend and M3Shapes
revisions against `windows/sources.lock.json`. A QML error, missing import or
plugin DLL, missing pass marker, or 90-second timeout fails the run.

The exit code is 0 on pass and 1 on failure, with a one-line summary. The
temporary stage, profile, stdout/stderr and Quickshell text log are removed on
pass, and kept with matched diagnostics printed on failure. The smoke also
fails if its captured output contains a MAC-like address or any
`quickshell.windows.bluetooth` activity, and it redacts those patterns from
failure output. `-TimeoutSeconds`, `-RunRoot` and `-Keep` help with debugging.
`QS_RUNTIME_DIR` only selects where Quickshell writes its own run/log files; it
is not a containment boundary and accepts relative, traversal and UNC paths.
The command does not install anything, run the live shell, or read the live
profile.

## Native bar/session prototype

After rebuilding for the Windows focus helper:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" -Wait -ScaleFactor native -ScreenIndex 0
```

This stages original ContentWindow/StyledWindow/Regions/Interactions, the bar
and session content, and explicit unavailable adapters in a fresh
`shell-runs/shell-<timestamp>/` directory. It opens one native panel window
inset 80 logical pixels, bounded to 900x620. Hover the left edge to show the bar;
Power opens the session drawer and Escape closes it. Session actions remain
unavailable. Do not use the root Linux `shell.qml`.

`-Wait` captures stdout/stderr until the process exits and then writes the
result JSON and source manifest under `logs/`; it is not a test pass.
Without `-Wait` or `-Smoke`, the launcher returns the child PID immediately.
Stop only that prototype PID when finished. `-BuildRoot` selects another output
directory. `-ScreenIndex` accepts 0-15 and fails if that screen does not exist.
`-ScaleFactor` accepts `native`, `1`, `1.5`, or `1.75`.

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" -Smoke -ScaleFactor native -ScreenIndex 0
```

Add `-MonitorCycle` to a native smoke run with at least two monitors to
open/capture/close, move the same ContentWindow to the next monitor, repeat,
and return. Results include `actualScreens` metadata and a `captures` array.
A rendered placement is not a pass if runtime warnings occur; see the
validation record for exact results. The corrected native cycle passed on
150% primary -> 175% negative-origin secondary -> primary with 900x620 geometry
and no QML diagnostics. The separate native input matrix now also validates
pointer/focus at both DPIs; smoke alone does not establish those results.

Smoke programmatically opens/closes the original content, checks geometry,
fonts, DPI and unavailable session actions, saves a PNG and exits. Input and
native focus activation are disabled during smoke. It has a 45-second outer
limit and a 15-second QML watchdog and rejects runtime warnings/errors.
Numeric scale overrides are synthetic child-process DPI tests; native uses
the selected display. Neither replaces real pointer/focus or same-process
mixed-DPI monitor tests. See the
[final acceptance record](validation/2026-10-25-m1-acceptance/README.md)
for the completed matrix, exact revisions and input limitations.

The launcher rewrites only its dedicated `shell-prototype-profile/config/shell.json`
to the audited Clock/Power/session slice. It isolates configuration, state,
runtime, data and cache; do not use this profile for personal customization.
It disables Windows blur for the child. The entry point skips
Drawers/Exclusions and Taskbar/Tiling controllers, while the backend still
initializes native support for its own window and shared stale-AppBar cleanup.
Quickshell also retains its own Windows instance bookkeeping.
No zero-global-bookkeeping guarantee is implied.
The tested palette is opaque. Disabled backend blur alone is not evidence of
system transparency being off; the separate opt-in input test verifies the
actual Windows preference and advanced-effects state.

For manual input evidence, launch the dedicated fixture in its own STA process:

```powershell
powershell -NoProfile -STA -File windows/scripts/Start-InputTarget.ps1
```

The WinForms fixture records JSONL mouse, activation, and keyboard events.
`-LogPath`, `-ClientWidth` and `-ClientHeight` select its output and client size.
It owns only that window/log and does not launch another application.
Capture read-only desktop state before/after a test:

```powershell
powershell -NoProfile -File windows/scripts/Get-DesktopState.ps1
```

For the separate M2 audio host, use `Start-ShellPrototype.ps1 -Audio
-AudioMode ReadOnly -Wait` with the same Qt prefix. Audio defaults disabled;
`Interactive` opts into explicit volume/routing writes and every smoke run
remains read-only. `Test-AudioPrototype.ps1 -QtPrefix <path>` runs the
read-only two-monitor/service gate. See the
[audio prototype instructions](audio-prototype/README.md) for exact commands,
failure semantics and limitations.

For the opt-in automated native input matrix, see
[the prototype instructions](shell-prototype/README.md). It uses `SendInput`
through real Windows routing, a dedicated fixture, exact-instance IPC, and
native 150%/175% monitor transfer. `-TestTransparencyOff` temporarily changes
and restores the current user's transparency preference. Keep pointer/keyboard
input idle during that test. It never enables tiling or taskbar control.

Optional `-OutputPath` saves the report. It queries physical monitor/work
rectangles, scale, taskbar flags, foreground PID/HWND and relevant process names/PIDs, preserving
negative origins. It changes only its measurement thread's DPI context
temporarily, not display/taskbar settings.

## Retained component probe

Launch an ordinary application window:

```powershell
powershell -NoProfile -File windows/scripts/Start-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64"
```

Click the original bar clock to open/close the motion specimen. Escape closes
it. Close the window to stop the process. An existing tiler may resize the
window; its 740 by 460 component specimen stays centered inside it.

For bounded automated rendering checks:

```powershell
foreach ($scale in @('1', '1.5', '1.75')) {
    powershell -NoProfile -File windows/scripts/Start-Prototype.ps1 `
        -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" -Smoke -ScaleFactor $scale
    if ($LASTEXITCODE -ne 0) { throw "Rendering check failed at $scale." }
}
```

These scale overrides affect only the child process. They disable Qt's native
scale factor, set the testing font DPI to 96, and apply the requested testing
factor, then assert the observed device pixel ratio. They do not change Windows display settings. This is
synthetic DPI coverage, not a mixed-monitor or native DPI transition test.
See [Qt's DPI testing reference](https://doc.qt.io/qt-6/highdpi.html#testing).

Each check allows 45 seconds for process startup and completion, with a separate
10-second in-app watchdog after QML loads. The initial run after a plugin
rebuild took about 19 seconds to produce its screenshot; warm runs took about
four seconds. Logs include timestamps and results include elapsed time.

Each check opens and closes the motion specimen, saves a PNG, and exits. It
fails on an incorrect DPI, dimensions, capture failure, timeout, or warning/error
in the runtime log. JSON results, source hashes, stdout, stderr, and screenshots
are saved under `logs/`. A result does not prove real pointer input, panel
keyboard focus, dismissal, or focus return.

The older probe stages an audited QML subset under `probe/` and creates configuration,
state, runtime, data, and cache directories under `probe-profile/`. An existing
probe configuration is preserved. Its palette is fixed and its clock icon is
disabled. The native prototype separately loads pinned
[Rubik/Material Symbols assets and licenses](assets/README.md); neither
prototype validates the dynamic theme service.

Quickshell records its own process bookkeeping under its Windows application
directory. The separate probe configuration path keeps its identity distinct.
The scripts do not change the current shell, taskbar configuration, tiler
configuration, autostart, credentials, or ordinary Caelestia configuration.
