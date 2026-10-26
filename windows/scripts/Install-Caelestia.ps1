[CmdletBinding()]
param(
    [string]$BuildRoot,
    [string]$QtPrefix,
    # Optional directory containing the x64 redistributable CRT DLLs.
    [string]$VCRuntimeRoot,
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows'),
    [string]$ProfileRoot = (Join-Path $env:LOCALAPPDATA 'caelestia-windows'),
    [switch]$Autostart
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
if (-not $QtPrefix) {
    $buildRecord = Join-Path $BuildRoot 'logs\build.json'
    if (Test-Path -LiteralPath $buildRecord) { $QtPrefix = (Get-Content -LiteralPath $buildRecord -Raw | ConvertFrom-Json).qtPrefix }
}
if (-not $QtPrefix) { throw 'Supply -QtPrefix for the Qt used to build qs.exe.' }
$QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
if (-not $VCRuntimeRoot) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsRoot) {
            $redist = Join-Path $vsRoot 'VC\Redist\MSVC'
            $version = Get-ChildItem -LiteralPath $redist -Directory |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
                Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
            if ($version) { $VCRuntimeRoot = Join-Path $version.FullName 'x64\Microsoft.VC143.CRT' }
        }
    }
}
if (-not $VCRuntimeRoot) { throw 'Supply -VCRuntimeRoot or install the Visual Studio x64 C++ redist files used by this build.' }
$VCRuntimeRoot = (Resolve-Path -LiteralPath $VCRuntimeRoot).Path
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $VCRuntimeRoot $dll))) { throw "Missing x64 CRT DLL: $dll" }
}
$Prefix = Resolve-CaelestiaDirectory $Prefix
$ProfileRoot = Resolve-CaelestiaDirectory $ProfileRoot
foreach ($sourceRoot in @($BuildRoot, $QtPrefix, $VCRuntimeRoot, $repoRoot, $ProfileRoot)) {
    if ($Prefix -eq $sourceRoot -or $sourceRoot.StartsWith($Prefix + '\', [StringComparison]::OrdinalIgnoreCase) -or $Prefix.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installation prefix must be separate from sources, build, Qt and profile: $sourceRoot"
    }
}
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$deploy = Join-Path $QtPrefix 'bin\windeployqt.exe'
foreach ($file in @("$BuildRoot\quickshell\qs.exe", $deploy, "$qmlRoot\Caelestia\Windows\qmldir", "$qmlRoot\M3Shapes\qmldir")) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing runtime prerequisite: $file" }
}
if (Test-Path -LiteralPath $Prefix) {
    if (Get-ChildItem -LiteralPath $Prefix -Force | Select-Object -First 1) {
        $old = Read-CaelestiaInstall $Prefix
        if ($old.profile -ne $ProfileRoot) { throw 'An update must retain the installed ProfileRoot.' }
    }
}
if (Get-CaelestiaProcesses $Prefix) { throw 'Quit this Caelestia installation before updating it.' }

# Assemble without writing to the supplied build tree or touching integration
# until Qt deployment succeeds. Each installed file comes from this payload.
$payload = Join-Path $env:TEMP ('caelestia-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $payload | Out-Null
try {
    Copy-Item -LiteralPath "$BuildRoot\quickshell\qs.exe" -Destination $payload
    New-Item -ItemType Directory -Path "$payload\qml", "$payload\defaults" | Out-Null
    Copy-Item -LiteralPath "$qmlRoot\Caelestia" -Destination "$payload\qml" -Recurse
    Copy-Item -LiteralPath "$qmlRoot\M3Shapes" -Destination "$payload\qml" -Recurse
    Copy-Item -LiteralPath "$qmlRoot\M3Shapes\m3shapes.dll" -Destination $payload
    # The portable plugins have shared helper DLLs outside their QML modules.
    Copy-Item -Path "$qmlRoot\Caelestia\lib\*.dll" -Destination $payload
    # App-local CRT deployment requires neither elevation nor a vcredist
    # installer, and does not depend on a machine-wide CRT installation.
    Copy-Item -Path "$VCRuntimeRoot\*.dll" -Destination $payload
    $stage = & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') -Destination "$payload\shell" -ProfileRoot $ProfileRoot -Prototype shell-live
    Copy-Item -LiteralPath "$repoRoot\windows\shell\shell.json" -Destination "$payload\defaults\shell.json"
    Copy-Item -LiteralPath "$repoRoot\windows\shell\windows.json" -Destination "$payload\defaults\windows.json"
    Copy-Item -LiteralPath "$repoRoot\defaults\windows\keybinds.json" -Destination "$payload\defaults\keybinds.json"
    foreach ($script in @('Start-Caelestia.ps1', 'Uninstall-Caelestia.ps1', 'Caelestia-InstallCommon.ps1', 'Start-DesktopShell.ps1', 'Watch-DesktopShell.ps1', 'Restore-Desktop.ps1', 'DesktopTakeover.cs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $script) -Destination $payload
    }
    New-Item -ItemType Directory -Path "$payload\licenses" | Out-Null
    Copy-Item -LiteralPath "$repoRoot\LICENSE", "$repoRoot\THIRD-PARTY-NOTICES.md" -Destination "$payload\licenses"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\m3shapes\LICENSE" -Destination "$payload\licenses\M3Shapes-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\LICENSE" -Destination "$payload\licenses\Caelestia-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE" -Destination "$payload\licenses\Quickshell-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE-GPL" -Destination "$payload\licenses\GPL-3.0.txt"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE" -Destination "$payload\licenses\LGPL-3.0.txt"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\src\windows\third_party\material_color\LICENSE" -Destination "$payload\licenses\MaterialColor-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\sources.lock.json" -Destination "$payload\licenses"
    # Keep component-relative paths and copyright/NOTICE files, including new
    # fonts and backend dependencies added after this packaging script.
    function Copy-LicenseTree([string]$Source, [string]$Destination) {
        foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse) {
            if ($file.Name -notmatch '(^|[._-])(LICENSE|LICENCE|COPYING|NOTICE|OFL)([._-].*)?$') { continue }
            $relative = $file.FullName.Substring($Source.TrimEnd('\').Length + 1)
            $target = Join-Path $Destination $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
    }
    Get-ChildItem -LiteralPath "$repoRoot\windows\licenses" -Force | Copy-Item -Destination "$payload\licenses" -Recurse
    Copy-LicenseTree "$repoRoot\assets" "$payload\licenses\fonts"
    Copy-LicenseTree "$repoRoot\windows\assets" "$payload\licenses\fonts"
    Copy-LicenseTree "$repoRoot\windows\deps\quickshell\src\windows\third_party" "$payload\licenses\Quickshell-third-party"
    New-Item -ItemType Directory -Force -Path "$payload\licenses\Qt" | Out-Null
    # The standard LGPL/GPL texts also apply to the dynamically deployed Qt
    # libraries. Some aqt prefixes contain only SBOMs, not LICENSES/.
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE" -Destination "$payload\licenses\Qt\LGPL-3.0.txt"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE-GPL" -Destination "$payload\licenses\Qt\GPL-3.0.txt"
    Copy-LicenseTree $QtPrefix "$payload\licenses\Qt"
    if (Test-Path -LiteralPath "$QtPrefix\licenses") {
        Get-ChildItem -LiteralPath "$QtPrefix\licenses" -Force | Copy-Item -Destination "$payload\licenses\Qt" -Recurse -Force
    }
    # The aqt Qt archive ships component licensing/provenance in SPDX SBOMs
    # rather than a top-level licenses directory.
    if (Test-Path -LiteralPath "$QtPrefix\sbom") {
        Copy-Item -LiteralPath "$QtPrefix\sbom" -Destination "$payload\licenses\Qt-sbom" -Recurse
    }
    # Resolve staged QML imports as well as DLL dependencies. Deployed Qt is
    # used at runtime; no development Qt prefix is recorded in the launcher.
    $ErrorActionPreference = 'Continue'
    & $deploy --verbose 0 --release --no-compiler-runtime --no-system-dxc-compiler --no-translations --dir $payload --plugindir "$payload\plugins" --qmldir $stage --qmlimport "$payload\qml" "$payload\qs.exe" 2>&1 | ForEach-Object { "$_" }
    $deployExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($deployExit -ne 0) { throw "windeployqt failed with exit code $deployExit" }
    @('[Paths]', 'Prefix=.', 'Plugins=plugins', 'QmlImports=qml') | Set-Content -LiteralPath "$payload\qt.conf" -Encoding ASCII
    $integration = Get-CaelestiaIntegration $Prefix
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix; profile = $ProfileRoot
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        executableSha256 = (Get-FileHash -LiteralPath "$payload\qs.exe").Hash
    } | ConvertTo-Json | Set-Content -LiteralPath "$payload\install.json" -Encoding UTF8

    New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
    Get-ChildItem -LiteralPath $payload -Force | Copy-Item -Destination $Prefix -Recurse -Force
    $launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
    $shortcutDir = Split-Path -Parent $integration.Shortcut
    New-Item -ItemType Directory -Force -Path $shortcutDir | Out-Null
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($integration.Shortcut)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $Prefix
    $shortcut.IconLocation = "$Prefix\qs.exe,0"
    $shortcut.Description = 'Caelestia for Windows'
    $shortcut.Save()
    if ($Autostart) {
        $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        New-Item -Path $run -Force | Out-Null
        New-ItemProperty -Path $run -Name $integration.RunName -PropertyType String -Value ('"' + $powershell + '" ' + $arguments) -Force | Out-Null
    }
    Write-Output "Installed Caelestia: $Prefix"
    Write-Output "Run: powershell -NoProfile -File `"$launcher`""
    Write-Output "Profile (seeded on first launch): $ProfileRoot"
} finally {
    # payload was created by this invocation under TEMP; verify before removal.
    $safePayload = Resolve-CaelestiaDirectory $payload
    if ((Split-Path -Parent $safePayload) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
        (Split-Path -Leaf $safePayload) -notlike 'caelestia-package-*') { throw 'Unsafe package cleanup path.' }
    Remove-Item -LiteralPath $safePayload -Recurse -Force
}
