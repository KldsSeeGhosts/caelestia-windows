$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-ef58734c'
$dev = 'C:\Users\Ermin\AppData\Local\caelestia-dev'
$qt = "$dev\Qt\6.11.2\msvc2022_64"
$installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$env:PATH = "$installer;$env:PATH"
$vs = & "$installer\vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
& "$vs\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$env:PATH = "$dev\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin;$qt\bin;$dev\tools\Scripts;$env:PATH"
$build = "$repo\windows\.local\build"
$ErrorActionPreference = 'Continue'
$manifestTool = Join-Path $env:WindowsSdkDir "bin\$($env:WindowsSDKVersion.TrimEnd('\'))\x64\mt.exe"
& cmake -S "$repo\windows\.local\tiling-backend\src\windows\test" -B "$build\backend-tests" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_LINKER_TYPE=MSVC "-DCMAKE_MT:FILEPATH=$manifestTool" "-DCMAKE_PREFIX_PATH=$qt" *> "$build\logs\configure-scoped-tests.log"
if ($LASTEXITCODE -ne 0) { throw 'Configure failed' }
& cmake --build "$build\backend-tests" --target tiling_observability_test --parallel 4 *> "$build\logs\build-scoped-tests.log"
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
& "$build\backend-tests\tiling_observability_test.exe" -o "$build\logs\scoped-rules-test.txt",txt
if ($LASTEXITCODE -ne 0) { throw 'Test failed' }
