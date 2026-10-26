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
& cmake -S $repo -B "$build\caelestia" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl "-DCMAKE_PREFIX_PATH=$qt" -DCAELESTIA_PORTABLE_UI=ON -DENABLE_MODULES=plugin -DINSTALL_QMLDIR=qml "-DCMAKE_INSTALL_PREFIX=$build\install" *> "$build\logs\configure-plugins.log"
if ($LASTEXITCODE -ne 0) { throw 'Configure failed' }
& cmake --build "$build\caelestia" --parallel 6 *> "$build\logs\build-plugins.log"
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
& cmake --install "$build\caelestia" *> "$build\logs\install-plugins.log"
if ($LASTEXITCODE -ne 0) { throw 'Install failed' }
[ordered]@{
    sourceRevision = (& git -C $repo rev-parse HEAD).Trim()
    sourceDirty = $true
    backendRevision = (& git -C "$repo\windows\.local\tiling-backend" rev-parse HEAD).Trim()
    backendDirty = [bool](& git -C "$repo\windows\.local\tiling-backend" status --porcelain)
    backendSource = "$repo\windows\.local\tiling-backend"
    qtVersion = '6.11.2'
    qtPrefix = $qt
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content "$build\logs\build.json" -Encoding UTF8
