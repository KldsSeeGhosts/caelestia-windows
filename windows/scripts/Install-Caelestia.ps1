[CmdletBinding()]
param(
    [string]$BuildRoot,
    [string]$QtPrefix,
    # Optional directory containing the x64 redistributable CRT DLLs.
    [string]$VCRuntimeRoot,
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows'),
    [string]$ProfileRoot = (Join-Path $env:LOCALAPPDATA 'caelestia-windows'),
    [switch]$Autostart,
    # Prepare with the current shell still running, then stop/swap/start.
    # The previous payload is retained until the replacement answers readiness.
    [switch]$Restart,
    # Accept a QtPrefix that differs from build.json, or a populated profile
    # this installer did not create (never purged by Uninstall).
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$buildRecord = Join-Path $BuildRoot 'logs\build.json'
if (Test-Path -LiteralPath $buildRecord) {
    $buildInfo = Get-Content -LiteralPath $buildRecord -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $buildInfo.sourceRevision -or -not $buildInfo.backendRevision) {
        throw "Build record $buildRecord must contain sourceRevision and backendRevision."
    }
    $sourceRevision = & git -C $repoRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $sourceRevision -ne $buildInfo.sourceRevision) {
        throw "Build source revision is $($buildInfo.sourceRevision), but checkout $repoRoot is at $sourceRevision. Run the installer from a checkout at $($buildInfo.sourceRevision), with its quickshell submodule at $($buildInfo.backendRevision)."
    }
    $backendRoot = Join-Path $repoRoot 'windows\deps\quickshell'
    if (-not (Test-Path -LiteralPath (Join-Path $backendRoot '.git'))) {
        throw "Quickshell submodule is not initialized in $repoRoot. Run the installer from a checkout at $($buildInfo.sourceRevision), with its quickshell submodule at $($buildInfo.backendRevision)."
    }
    $backendRevision = & git -C $backendRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $backendRevision -ne $buildInfo.backendRevision) {
        throw "Build backend revision is $($buildInfo.backendRevision), but checkout $repoRoot has quickshell at $backendRevision. Run the installer from a checkout at $($buildInfo.sourceRevision), with its quickshell submodule at $($buildInfo.backendRevision)."
    }
    # Matching HEADs do not prove matching content. Installing local QML edits
    # is a normal development step, so warn rather than refuse.
    if ($buildInfo.sourceDirty -or (& git -C $repoRoot status --porcelain)) {
        Write-Warning "The build or checkout has uncommitted changes; install.json sourceRevision $sourceRevision may not describe the installed files."
    }
} else {
    Write-Warning "Build record not found at $buildRecord; source and backend revisions cannot be verified."
}
$explicitQtPrefix = $QtPrefix
if (-not $QtPrefix) {
    if ($buildInfo) { $QtPrefix = $buildInfo.qtPrefix }
}
if (-not $QtPrefix) { throw 'Supply -QtPrefix for the Qt used to build qs.exe.' }
$QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
if ($explicitQtPrefix -and $buildInfo -and $buildInfo.qtPrefix -and -not $Force) {
    $recordedQt = [IO.Path]::GetFullPath([string]$buildInfo.qtPrefix).TrimEnd('\')
    if ($recordedQt -ne $QtPrefix.TrimEnd('\')) {
        throw "-QtPrefix $QtPrefix differs from the Qt recorded in build.json ($recordedQt). Deploying a different Qt than qs.exe was built with can fail at runtime; pass -Force to accept."
    }
}
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
# Serialize preparation as well as activation. Otherwise two simultaneous
# updates can both pass the staging scan and overwrite the same rollback tree.
$installLock = Enter-CaelestiaInstallLock $Prefix
try {
if (-not $installLock) { throw "Another installation is in progress for $Prefix." }
# Recover from an interrupted earlier swap or staging run only when the sibling
# directory carries Caelestia ownership evidence and has no reparse points.
$prefixParent = Split-Path -Parent $Prefix
$prefixLeaf = Split-Path -Leaf $Prefix
$backup = "$Prefix.old"
if (Test-Path -LiteralPath $backup) {
    $backup = Resolve-CaelestiaDirectory $backup
    $backupInstall = Join-Path $backup 'install.json'
    if (-not (Test-Path -LiteralPath $backupInstall -PathType Leaf)) {
        throw "Refusing to touch unowned backup directory without install.json: $backup"
    }
    $backupRecord = Get-Content -LiteralPath $backupInstall -Raw | ConvertFrom-Json
    if ($backupRecord.product -ne 'caelestia-windows' -or $backupRecord.prefix -ne $Prefix) {
        throw "Refusing to touch backup directory belonging to another installation: $backup"
    }
    if (-not (Test-Path -LiteralPath $Prefix)) { [IO.Directory]::Move($backup, $Prefix) }
    else { Assert-CaelestiaNoReparsePoints $backup; Remove-Item -LiteralPath $backup -Recurse -Force }
}
if (Test-Path -LiteralPath $prefixParent) {
    foreach ($leftover in Get-ChildItem -LiteralPath $prefixParent -Directory -Force -Filter "$prefixLeaf.staging-*") {
        $leftoverPath = Resolve-CaelestiaDirectory $leftover.FullName
        $leftoverPid = ($leftover.Name -replace '^.*\.staging-', '') -as [int]
        if ($leftoverPid -and (Get-Process -Id $leftoverPid -ErrorAction SilentlyContinue)) { throw "Another installation is in progress: $leftoverPath" }
        $stagingMarker = Join-Path $leftoverPath '.caelestia-staging.json'
        $hasOwnership = (Test-Path -LiteralPath $stagingMarker -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $leftoverPath 'install.json') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $leftoverPath 'qs.exe') -PathType Leaf)
        if (-not $hasOwnership) {
            throw "Refusing to remove unowned staging directory: $leftoverPath"
        }
        Assert-CaelestiaNoReparsePoints $leftoverPath
        Remove-Item -LiteralPath $leftoverPath -Recurse -Force
    }
}
$old = $null
if ((Test-Path -LiteralPath $Prefix) -and (Get-ChildItem -LiteralPath $Prefix -Force | Select-Object -First 1)) {
    if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) {
        $old = Read-CaelestiaInstall $Prefix
        if ($old.installRoot -and $old.installRoot -ne $Prefix) {
            throw 'Do not install into an immutable version directory. Use its stable installRoot.'
        }
        if ($old.profile -ne $ProfileRoot) { throw 'An update must retain the installed ProfileRoot.' }
    } elseif (-not $Force -or -not ((Test-Path -LiteralPath (Join-Path $Prefix 'qs.exe')) -or (Test-Path -LiteralPath (Join-Path $Prefix 'Start-Caelestia.ps1')))) {
        # Only an interrupted Caelestia copy (no install.json) can be replaced, and only with -Force.
        throw "$Prefix is not a recognized Caelestia installation. A partial install of Caelestia can be replaced with -Force."
    }
}
# Quit this installation's shell and supervisor (including restart backoff,
# when no qs.exe exists) before replacing files under a live watchdog.
if (-not $Restart) {
    if (Get-CaelestiaProcesses $Prefix) { throw 'Use -Restart to prepare a live update, or quit this Caelestia installation before updating it.' }
    if (@(Get-CaelestiaSupervisors $ProfileRoot).Count) { throw 'A Caelestia desktop supervisor is still running for this profile. Use -Restart for a live update.' }
}
# Profile ownership: an uninstall -Purge may delete only a profile created for
# this prefix, so refuse to adopt someone else's populated directory.
$profileExclusive = $true
if (-not (Test-CaelestiaProfileEmpty $ProfileRoot)) {
    $owner = Read-CaelestiaProfileOwner $ProfileRoot
    if ($owner) {
        if ($owner.prefix -ne $Prefix) {
            if (-not $Force) { throw "ProfileRoot $ProfileRoot belongs to another Caelestia installation ($($owner.prefix)). Choose a separate profile, or pass -Force to share it." }
            $profileExclusive = $false
        } else { $profileExclusive = [bool]$owner.exclusive }
    } elseif ($old) {
        # Populated profile without a prior ownership marker is kept non-exclusive
        # so Uninstall -Purge never removes pre-existing unmarked directories.
        $profileExclusive = $false
    } elseif ($Force) {
        $profileExclusive = $false
    } else {
        throw "ProfileRoot $ProfileRoot is not empty and has no Caelestia ownership marker. Use an empty directory, or pass -Force (the profile is then never removed by Uninstall -Purge)."
    }
}
$installId = if ($old -and $old.installId) { [string]$old.installId } else { [guid]::NewGuid().ToString('N') }

# Assemble without writing to the supplied build tree or touching integration
# until Qt deployment succeeds. Each installed file comes from this payload.
# The payload is a sibling of the prefix, so the final swap is a same-volume rename.
$payload = "$Prefix.staging-$PID"
$preparation = [Diagnostics.Stopwatch]::StartNew()
New-Item -ItemType Directory -Force -Path $prefixParent | Out-Null
New-Item -ItemType Directory -Path $payload | Out-Null
try {
    [ordered]@{ product = 'caelestia-windows'; prefix = $Prefix; pid = $PID } | ConvertTo-Json | Set-Content -LiteralPath "$payload\.caelestia-staging.json" -Encoding UTF8
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
    foreach ($script in @('Start-Caelestia.ps1', 'Start-CaelestiaEntry.ps1', 'Manage-Caelestia.ps1', 'Caelestia-Versions.ps1', 'Uninstall-Caelestia.ps1', 'Caelestia-InstallCommon.ps1', 'Start-DesktopShell.ps1', 'Watch-DesktopShell.ps1', 'Restore-Desktop.ps1', 'DesktopTakeover.cs', 'Install-SchemeRuntime.ps1', 'Get-AccountPicture.ps1', 'Banner-Suppression.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $script) -Destination $payload
    }
    # Compile once while the old shell is alive, not on every watchdog launch.
    # Always target Windows PowerShell's .NET Framework, even from pwsh 7.
    $compile = "Add-Type -Path '" + "$payload\DesktopTakeover.cs".Replace("'", "''") +
        "' -OutputAssembly '" + "$payload\DesktopTakeover.dll".Replace("'", "''") +
        "' -ReferencedAssemblies System.Windows.Forms,System.Web.Extensions -ErrorAction Stop"
    & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -Command $compile
    if ($LASTEXITCODE -ne 0) { throw 'Desktop supervisor compilation failed; the current installation was left running.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'scheme') -Destination $payload -Recurse
    New-Item -ItemType Directory -Path "$payload\licenses" | Out-Null
    Copy-Item -LiteralPath "$repoRoot\LICENSE", "$repoRoot\THIRD-PARTY-NOTICES.md" -Destination "$payload\licenses"
    Copy-Item -LiteralPath "$repoRoot\windows\services\clipboard\upstream\LICENSE-MIT.txt" -Destination "$payload\licenses\Clipboard-Overlay-MIT.txt"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\m3shapes\LICENSE" -Destination "$payload\licenses\M3Shapes-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\LICENSE" -Destination "$payload\licenses\Caelestia-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE" -Destination "$payload\licenses\Quickshell-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE-GPL" -Destination "$payload\licenses\GPL-3.0.txt"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\LICENSE" -Destination "$payload\licenses\LGPL-3.0.txt"
    Copy-Item -LiteralPath "$repoRoot\windows\deps\quickshell\src\windows\third_party\material_color\LICENSE" -Destination "$payload\licenses\MaterialColor-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\sources.lock.json" -Destination "$payload\licenses"
    # Keep component-relative paths and copyright/NOTICE files, including new
    # fonts and backend dependencies added after this packaging script.
    function Copy-LicenseTree([string]$Source, [string]$Destination, [switch]$KeepLicenseDirs) {
        foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse) {
            $relative = $file.FullName.Substring($Source.TrimEnd('\').Length + 1)
            # Qt names its texts by SPDX id (LGPL-3.0-only.txt) inside LICENSES/;
            # every file there is a license text. The top-level directory is
            # copied wholesale below.
            $inLicenseDir = $KeepLicenseDirs -and $relative -imatch '\\LICENSES\\' -and $relative -inotmatch '^LICENSES\\'
            if (-not $inLicenseDir -and $file.Name -notmatch '(^|[._-])(LICENSE|LICENCE|COPYING|NOTICE|OFL)([._-].*)?$') { continue }
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
    Copy-LicenseTree $QtPrefix "$payload\licenses\Qt" -KeepLicenseDirs
    # Qt's LICENSES/ directory (case-insensitive on Windows) is copied whole.
    if (Test-Path -LiteralPath "$QtPrefix\LICENSES") {
        Get-ChildItem -LiteralPath "$QtPrefix\LICENSES" -Force | Copy-Item -Destination "$payload\licenses\Qt" -Recurse -Force
    }
    # The aqt Qt archive ships component licensing/provenance in SPDX SBOMs
    # rather than a top-level licenses directory.
    if (Test-Path -LiteralPath "$QtPrefix\sbom") {
        Copy-Item -LiteralPath "$QtPrefix\sbom" -Destination "$payload\licenses\Qt-sbom" -Recurse
    }
    # Resolve staged QML imports as well as DLL dependencies. Deployed Qt is
    # used at runtime; no development Qt prefix is recorded in the launcher.
    # The aqt Qt archive omits the separate qttranslations component, so
    # windeployqt still prints "Translations will not be available ...
    # catalogs.json" with --no-translations. That message is informational:
    # this installer deliberately ships no Qt catalogs and the shell installs
    # no QTranslator, so deployment proceeds and runtime strings stay English.
    $ErrorActionPreference = 'Continue'
    & $deploy --verbose 0 --release --no-compiler-runtime --no-system-dxc-compiler --no-translations --dir $payload --plugindir "$payload\plugins" --qmldir $stage --qmlimport "$payload\qml" "$payload\qs.exe" 2>&1 | ForEach-Object { "$_" }
    $deployExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($deployExit -ne 0) { throw "windeployqt failed with exit code $deployExit" }
    @('[Paths]', 'Prefix=.', 'Plugins=plugins', 'QmlImports=qml') | Set-Content -LiteralPath "$payload\qt.conf" -Encoding ASCII
    $integration = Get-CaelestiaIntegration $Prefix
    # install.json is written last: a staging directory without it is not an install.
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix; profile = $ProfileRoot
        installId = $installId
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        backendRevision = $(if ($buildInfo) { $buildInfo.backendRevision } else { '' })
        executableSha256 = (Get-FileHash -LiteralPath "$payload\qs.exe").Hash
    } | ConvertTo-Json | Set-Content -LiteralPath "$payload\install.json" -Encoding UTF8
    Remove-Item -LiteralPath "$payload\.caelestia-staging.json" -Force -ErrorAction SilentlyContinue

    Write-CaelestiaProfileOwner $ProfileRoot $Prefix $installId $profileExclusive
    Write-Output ('Payload assembled in {0:N2}s.' -f $preparation.Elapsed.TotalSeconds)
    $runtimePrefix = Install-CaelestiaVersion $Prefix $payload -Restart:$Restart
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
    $shortcut.IconLocation = "$runtimePrefix\qs.exe,0"
    $shortcut.Description = 'Caelestia for Windows'
    $shortcut.Save()
    if ($Autostart) {
        $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        New-Item -Path $run -Force | Out-Null
        New-ItemProperty -Path $run -Name $integration.RunName -PropertyType String -Value ('"' + $powershell + '" ' + $arguments) -Force | Out-Null
    }
    Remove-CaelestiaRetiredVersions $Prefix
    Write-Output "Installed Caelestia: $Prefix"
    Write-Output "Run: powershell -NoProfile -File `"$launcher`""
    Write-Output "Profile (seeded on first launch): $ProfileRoot"
} finally {
    # The staging directory is renamed on success; remove only this run's leftover.
    if (Test-Path -LiteralPath $payload) {
        $safePayload = Resolve-CaelestiaDirectory $payload
        if ((Split-Path -Parent $safePayload) -ne $prefixParent -or
            (Split-Path -Leaf $safePayload) -ne "$prefixLeaf.staging-$PID") { throw 'Unsafe package cleanup path.' }
        Remove-Item -LiteralPath $safePayload -Recurse -Force
    }
}
} finally {
    Exit-CaelestiaInstallLock $installLock
}
