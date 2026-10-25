# Native Windows component probe

The first verified build uses Windows 11, Qt 6.11.2 `msvc2022_64`, clang-cl
20.1.8, Visual Studio Build Tools 2022, Windows SDK 10.0.26100.0, CMake 4.4.4,
Ninja 1.13.2, and CLI11 2.5.0. A successful run proves the portable plugin and
component subset described in [README.md](README.md), not the full M1 shell.

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
Qt repository layout. Keep its log outside the source checkout:

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
(default 4). The default directory is `windows/.local/build`.

The script:

1. Runs `Test-Environment.ps1 -Json -Strict` in the development environment and
   checks that the backend worktree is clean and matches the source manifest.
2. Builds the pinned backend's `qs.exe` with crash handling and backend tests
   disabled. This does not execute the shell or enable autostart.
3. Builds Caelestia with `CAELESTIA_PORTABLE_UI=ON` and `ENABLE_MODULES=plugin`.
4. Installs the eight plugin modules into the build directory's `install/qml`.
5. Records command arguments, logs, source revisions, and tool versions under
   `logs/`. No packages are published.

## Run and check

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

Each check opens and closes the motion specimen, saves a PNG, and exits. It
fails on an incorrect DPI, dimensions, capture failure, timeout, or warning/error
in the runtime log. JSON results, source hashes, stdout, stderr, and screenshots
are saved under `logs/`. A result does not prove real pointer input, panel
keyboard focus, dismissal, or focus return.

The probe stages an audited QML subset under `probe/` and creates configuration,
state, runtime, data, and cache directories under `probe-profile/`. An existing
probe configuration is preserved. Its palette is fixed and its clock icon is
disabled; full theme and font coverage remain open.

Quickshell records its own process bookkeeping under its Windows application
directory. The separate probe configuration path keeps its identity distinct.
The scripts do not change the current shell, taskbar configuration, tiler
configuration, autostart, credentials, or ordinary Caelestia configuration.
