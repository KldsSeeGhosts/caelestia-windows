$ErrorActionPreference = 'Stop'
$dev = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$env:PATH = (Split-Path -Parent $vswhere) + ';' + $env:PATH
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
& (Join-Path $vs 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$env:PATH = "$dev\tools\Scripts;$dev\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin;$dev\Qt\6.11.2\msvc2022_64\bin;$env:PATH"
$target = Join-Path $PSScriptRoot 'build\quickshell'
& cmake -S D:/AiStack/caelestia-windows/windows/.local/qs-livefix -B $target -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_C_COMPILER=clang-cl "-DCMAKE_PREFIX_PATH=$dev\Qt\6.11.2\msvc2022_64" "-DCLI11_INCLUDE_DIR=$dev\deps\CLI11-2.5.0\include" -DCRASH_HANDLER=OFF -DBUILD_TESTING=OFF -DINSTALL_QMLDIR=qml -DQS_AUTOSTART_NAME=CaelestiaPrototype -DQS_AUTOSTART_ARGS= '-DQS_AUTOSTART_DESCRIPTION=Caelestia compatibility prototype'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& cmake --build $target --target quickshell --parallel 8
exit $LASTEXITCODE
