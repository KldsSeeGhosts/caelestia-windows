$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-ef58734c'
$dev = 'C:\Users\Ermin\AppData\Local\caelestia-dev'
$qt = "$dev\Qt\6.11.2\msvc2022_64"
$llvm = "$dev\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin"
$tools = "$dev\tools\Scripts"
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$env:PATH = "$installer;$env:PATH"
$vs = & "$installer\vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
& "$vs\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$env:PATH = "$llvm;$qt\bin;$tools;$env:PATH"
$build = "$repo\windows\.local\build"
New-Item -ItemType Directory -Force "$build\logs" | Out-Null
$ErrorActionPreference = 'Continue'
& cmake -S "$repo\windows\.local\tiling-backend" -B "$build\quickshell" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_C_COMPILER=clang-cl "-DCMAKE_PREFIX_PATH=$qt" "-DCLI11_INCLUDE_DIR=$dev\deps\CLI11-2.5.0\include" -DCRASH_HANDLER=OFF -DBUILD_TESTING=OFF -DINSTALL_QMLDIR=qml -DQS_AUTOSTART_NAME=CaelestiaPrototype -DQS_AUTOSTART_ARGS= '-DQS_AUTOSTART_DESCRIPTION=Caelestia compatibility prototype' *> "$build\logs\configure-backend.log"
if ($LASTEXITCODE -ne 0) { throw 'Configure failed' }
& cmake --build "$build\quickshell" --target quickshell --parallel 6 *> "$build\logs\build-backend.log"
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
Copy-Item -LiteralPath 'C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-325d7919\windows\.local\build\install' -Destination "$build\install" -Recurse
