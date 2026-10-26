# Tiling gaps and scheme borders

Built clean shell `ffe14703ad947817827d362d0ed36c2e47981d96` from
`08c34968db3b55e6f625e6ffd2186182d61c1e59` and backend
`087620807ae628ead13ec50b389fd536c2ed0fe8` from
`c1177c2771ecc3e9fd282449bdb08314576ca271`.
The following commit adds this evidence only.

Build output:

```text
C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-1cef1f78\windows\.local\build
```

## Changes

- Keep the existing per-side meaning of `gapsIn`, defaulting to 5 DIPs for a
  total of 10 between tiles. `gapsOut` defaults to 10.
- Add `singleWindowGapsOut`, default 20 DIPs, for exactly one tiled window
  per monitor/workspace in all three layout engines. Hidden/minimized and
  suspended/maximized windows do not count.
- Add `borderColours`, default true. Native DWM borders follow focus and the
  scheme on Windows 11 build 22000+. Primary at 0xe6 and onSurfaceVariant at
  0x11 are composited against surface in QML, then passed as opaque COLORREFs.
  The backend restores the default colour on unmanagement, disable, normal
  application exit and manager destruction. Unsupported Windows skips writes.
- Both new profile keys reload through the existing configuration path.
  Native maximize, border width and rounding remain owned by Windows.
  The user guide, configuration reference and tiling schema explain this.
- One case was added to the existing fake-desktop manager suite, covering
  single/multiple/minimized windows, gap changes, focus/scheme changes,
  exclusion/unmanagement, option/session/exit cleanup and unsupported builds.
  Two existing geometry expectations were updated for the new defaults.

## Build and prerequisite report

All native build steps completed with Qt 6.11.2, clang-cl 20.1.8, MSVC
14.44.35207 and SDK 10.0.26100.0. The strict environment report confirms both
dependency pins. Configure/compiler warnings remain in the build logs.

The Python `tools\Scripts\cmake.exe` launcher was blocked by Application
Control. The already installed CMake 4.4.4 binary ran successfully:

```powershell
$dev = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
$env:PATH = "$dev\tools\Scripts;$env:PATH"
& windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$dev\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$dev\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$dev\deps\CLI11-2.5.0\include" `
    -ToolsBin "$dev\tools\Lib\site-packages\cmake\data\bin" -Jobs 8
```

The existing standalone Windows backend test project was configured into
`windows\.local\build\tiling-tests`, and only `tiling_manager_test` was built.
LLVM's manifest merger produced namespaced `level`/`uiAccess` attributes which
Windows rejected. Windows SDK `mt.exe` successfully re-embedded the generated
`asInvoker` manifest, but Application Control then blocked execution. No unit
test pass is claimed. Security policy was not changed.

## One combined smoke, incomplete

The Windows backend requires Qt's Windows platform, so offscreen Qt cannot
exercise this graph. The existing combined smoke command ran on a separate
non-visible Win32 desktop, `winsta0\CaelestiaTilingGapsSmoke`, without switching
the input desktop. An ephemeral CreateDesktop/CreateProcess launcher kept that
desktop open during the attempt. It added no assertions or new test harness.
The child command was:

```powershell
& windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -Combined -Smoke -Tiling -TilingMode Observe -SkipSchemeRuntime
```

Exactly one `qs.exe` smoke instance ran, PID 25012. Desktop enumeration confirmed
its windows existed on the separate desktop. The configuration loaded, rendered
its first panel frame and logged:

```text
CAELESTIA_TILING_OPTIONS gapsIn=5 gapsOut=10 singleWindowGapsOut=20 borderColours=true
CAELESTIA_COMBINED_SERVICE name=tiling mode=observe status=observing backendEnabled=false managed=0 failed=0 included=0 excluded=0
```

No runtime warnings/errors were logged before the attempt ended. The smoke did
not complete before the desktop launcher's 60-second limit, and no completion
marker or capture was produced. The launcher and smoke processes have exited.
This is an incomplete smoke, not a pass. The raw native runtime log was
recovered from this instance's Quickshell bookkeeping directory.

Before/after snapshots match for real monitor/work rectangles, taskbar flags,
Explorer/live shell PIDs and foreground. The live shell remained PID 756.
Neither the installed application nor its profile was written.

The inherited backend startup cleanup logged removal of four AppBar
registrations as stale on the separate desktop. This is a shared-bookkeeping
side effect even though the observed real work area/taskbar state did not
change. It prevents claiming zero global side effects from this isolation
method. No second interactive tiler, desktop takeover, autostart, taskbar
visibility changes or live-window placement/border writes were enabled.

Live gap placement, border appearance, theme switching and restoration remain
for the user's installation check. The failed test execution and incomplete
smoke do not validate those behaviors.

See [result.json](result.json), [matrix.json](matrix.json), the build logs,
the native [runtime log](combined/runtime.log) and desktop snapshots.
No staged QML, per-run `sources.json` or other existing archives were copied.
The DWM implementation follows Microsoft's
[DWMWINDOWATTRIBUTE documentation](https://learn.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute).
