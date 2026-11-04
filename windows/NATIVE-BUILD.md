# Native Windows build and validation

The supported build uses Windows 11, Qt 6.11.2 `msvc2022_64`, clang-cl 20.1.8,
Visual Studio Build Tools 2022, Windows SDK 10.0.26100.0, CMake 4.4.4,
Ninja 1.13.2, and CLI11 2.5.0. The production entry point is
`windows/shell/shell.qml`. A build or smoke pass does not establish live
desktop acceptance; use [LIVE-CHECKLIST.md](docs/LIVE-CHECKLIST.md) for that.

## Developer dependencies

Visual Studio Build Tools must already include the x64 C++ tools and Windows
SDK. The build script discovers them with `vswhere.exe` and enters their
environment in its own process. No machine PATH or Visual Studio installation
is changed by the build script.

The following setup commands download development tools into a separate
per-user directory. Run them in native Windows PowerShell. Python 3.12, Git,
`curl.exe`, and `tar.exe` must be available. Production builds also bundle the
Glazier recorder from the pinned `windows/deps/glazier` submodule, so the Rust
toolchain (`cargo` on PATH, installed with [rustup](https://rustup.rs/)) is
required. Offscreen fixture builds can pass `-SkipGlazier` instead, but their
payload is not installable.

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

## Service fixtures and live checks

The pure service fixtures force Qt's offscreen platform themselves and use
fake backends. Run them from a disposable working directory after building:

```powershell
$repo = (Resolve-Path .).Path
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$run = Join-Path $env:TEMP ('caelestia-services-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
Push-Location $run
try {
    Get-ChildItem "$repo\windows\scripts\Test-*Service.ps1" | ForEach-Object {
        & $_.FullName -QtPrefix $qtPrefix -BuildRoot C:\b-smoke
    }
} finally {
    Pop-Location
}
```

Adapter fixtures, plugin tests, JS-module tests, `Test-BackendNative.ps1` and
the versioned installation tests remain separate. Run only suites appropriate
to the change; native integration checks may open windows or change desktop
state and require exclusive desktop ownership.

Use [LIVE-CHECKLIST.md](docs/LIVE-CHECKLIST.md) for installed-shell acceptance.
Builds and offscreen fixtures cannot establish real input, device control or
mixed-DPI behavior. Records under `windows/validation/` describe their own
source revisions.

`Build-Prototype.ps1` and `Start-ShellPrototype.ps1` retain their existing names.
The latter still supports the `-Combined` developer preview described in the
[user guide](docs/USER-GUIDE.md#running-from-a-developer-build-combined-preview).
Its entry point and support assets live under `windows/tests/fixtures/` because
the launcher, runtime benchmarks and native integration checks still use them.
They are never included in the installed shell's production staging map.
