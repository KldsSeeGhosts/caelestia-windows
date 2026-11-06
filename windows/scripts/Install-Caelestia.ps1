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
    [switch]$Force,
    # Skip preparing the optional profile-local Python scheme runtime during
    # this install. An existing prepared runtime is still used; a later
    # launcher start may provision one. Useful offline and in installer tests.
    [switch]$SkipSchemeRuntime,
    # Package another exact checkout with the same assembly tooling for A/B.
    [string]$SourceRoot,
    # Disposable-prefix packaging: no shortcut, HKCU Run entry or launch task.
    [switch]$NoIntegration,
    [string]$TimingFile,
    # Diagnostics: compare compilation with the verified immutable cache.
    [switch]$NoSupervisorCache
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if ($SourceRoot) { $repoRoot = (Resolve-Path -LiteralPath $SourceRoot).Path }
. (Join-Path $repoRoot 'windows\capture\Source.ps1')
if ($NoIntegration -and ($Restart -or $Autostart -or
    [IO.Path]::GetFullPath($Prefix).TrimEnd('\') -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows')).TrimEnd('\'))) {
    throw '-NoIntegration requires a separate prefix and cannot launch or register autostart.'
}
$timings = [ordered]@{}
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$buildRecord = Join-Path $BuildRoot 'logs\build.json'
if (Test-Path -LiteralPath $buildRecord) {
    $buildInfo = Get-Content -LiteralPath $buildRecord -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $buildInfo.sourceRevision -or -not $buildInfo.backendRevision) {
        throw "Build record $buildRecord must contain sourceRevision and backendRevision."
    }
    $sourceRevision = & git -C $repoRoot rev-parse HEAD
    $nativeOverride = $false
    if ($SourceRoot -and $sourceRevision -ne $buildInfo.sourceRevision -and -not $buildInfo.sourceDirty) {
        $changedInputs = @(& git -C $repoRoot diff --name-only $buildInfo.sourceRevision $sourceRevision)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot verify native inputs of the source override.' }
        $nativeInputs = @($changedInputs | Where-Object {
            Test-CaelestiaCaptureNativeInput $_ })
        $nativeOverride = $nativeInputs.Count -eq 0
    }
    if ($LASTEXITCODE -ne 0 -or ($sourceRevision -ne $buildInfo.sourceRevision -and -not $nativeOverride)) {
        throw "Build source revision is $($buildInfo.sourceRevision), but checkout $repoRoot is at $sourceRevision. Run the installer from a checkout at $($buildInfo.sourceRevision), with its quickshell submodule at $($buildInfo.backendRevision)."
    }
    if ($nativeOverride) { Write-Verbose "QML-only source override: $sourceRevision; native build $($buildInfo.sourceRevision)." }
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
# Caelestia capture is bundled beside qs.exe, never downloaded or resolved from a
# machine-wide location. The whole versioned payload carries it.
$glazierSource = Join-Path $BuildRoot 'install\caelestia-capture.exe'
foreach ($file in @("$BuildRoot\quickshell\qs.exe", $glazierSource, $deploy, "$qmlRoot\Caelestia\Windows\qmldir", "$qmlRoot\M3Shapes\qmldir")) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing runtime prerequisite: $file" }
}
if ($buildInfo) {
    Assert-CaelestiaCaptureBuild $buildInfo (Get-CaelestiaCaptureSource $repoRoot) $glazierSource
}
# Serialize preparation as well as activation. Otherwise two simultaneous
# updates can both pass the staging scan and overwrite the same rollback tree.
$installLock = Enter-CaelestiaInstallLock $Prefix
try {
if (-not $installLock) { throw "Another installation is in progress for $Prefix." }
$prefixParent = Split-Path -Parent $Prefix
$prefixLeaf = Split-Path -Leaf $Prefix
$context = Initialize-CaelestiaInstall $Prefix $ProfileRoot -Restart:$Restart -Force:$Force
$old = $context.Old
$profileExclusive = $context.ProfileExclusive
$installId = $context.InstallId

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
    Copy-Item -LiteralPath $glazierSource -Destination $payload
    New-Item -ItemType Directory -Path "$payload\qml", "$payload\defaults" | Out-Null
    Copy-Item -LiteralPath "$qmlRoot\Caelestia" -Destination "$payload\qml" -Recurse
    Copy-Item -LiteralPath "$qmlRoot\M3Shapes" -Destination "$payload\qml" -Recurse
    Copy-Item -LiteralPath "$qmlRoot\M3Shapes\m3shapes.dll" -Destination $payload
    # The portable plugins have shared helper DLLs outside their QML modules.
    Copy-Item -Path "$qmlRoot\Caelestia\lib\*.dll" -Destination $payload
    # App-local CRT deployment requires neither elevation nor a vcredist
    # installer, and does not depend on a machine-wide CRT installation.
    Copy-Item -Path "$VCRuntimeRoot\*.dll" -Destination $payload
    $timings.copyNativeSeconds = $preparation.Elapsed.TotalSeconds
    $phaseClock = [Diagnostics.Stopwatch]::StartNew()
    $stage = & (Join-Path $repoRoot 'windows\scripts\Stage-ShellPrototype.ps1') -Destination "$payload\shell" -ProfileRoot $ProfileRoot -Prototype shell-live
    $timings.stageQmlSeconds = $phaseClock.Elapsed.TotalSeconds
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
    $phaseClock.Restart()
    $supervisorSourceHash = (Get-FileHash -LiteralPath "$payload\DesktopTakeover.cs").Hash
    $supervisorCached = $false
    if ($old -and -not $NoSupervisorCache) {
        $prior = if ($old.version -eq 2) { Get-CaelestiaVersionPrefix $Prefix $old.current } else { $Prefix }
        $priorMetadata = Join-Path $prior 'DesktopTakeover.build.json'
        $priorAssembly = Join-Path $prior 'DesktopTakeover.dll'
        if ((Test-Path -LiteralPath $priorMetadata -PathType Leaf) -and (Test-Path -LiteralPath $priorAssembly -PathType Leaf)) {
            try {
                $cached = Get-Content -LiteralPath $priorMetadata -Raw | ConvertFrom-Json
                if ($cached.sourceSha256 -eq $supervisorSourceHash -and
                    $cached.clrVersion -eq [Environment]::Version.ToString() -and
                    (Get-FileHash -LiteralPath $priorAssembly).Hash -eq $cached.assemblySha256 -and
                    -not ((Get-Item -LiteralPath $priorAssembly).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    Copy-Item -LiteralPath $priorAssembly -Destination "$payload\DesktopTakeover.dll"
                    $supervisorCached = $true
                }
            } catch {
                # An absent, unreadable or changed cache is a miss. Compile from
                # the source being installed; never trust a stale DLL alone.
                Remove-Item -LiteralPath "$payload\DesktopTakeover.dll" -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if (-not $supervisorCached) {
        & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -Command $compile
        if ($LASTEXITCODE -ne 0) { throw 'Desktop supervisor compilation failed; the current installation was left running.' }
    }
    [ordered]@{ sourceSha256=$supervisorSourceHash; assemblySha256=(Get-FileHash -LiteralPath "$payload\DesktopTakeover.dll").Hash
        clrVersion=[Environment]::Version.ToString() } | ConvertTo-Json |
        Set-Content -LiteralPath "$payload\DesktopTakeover.build.json" -Encoding UTF8
    $timings.compileSupervisorSeconds = $phaseClock.Elapsed.TotalSeconds
    $timings.supervisorCacheHit = $supervisorCached
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
    # Glazier's MIT licence and its own upstream third-party notices travel
    # with the bundled executable.
    Copy-Item -LiteralPath "$repoRoot\windows\capture\LICENSE" -Destination "$payload\licenses\Glazier-LICENSE"
    Copy-Item -LiteralPath "$repoRoot\windows\capture\THIRD_PARTY_NOTICES.md" -Destination "$payload\licenses\Glazier-THIRD_PARTY_NOTICES.md"
    Copy-Item -LiteralPath "$repoRoot\windows\capture\ORIGIN.md" -Destination "$payload\licenses\Caelestia-Capture-ORIGIN.md"
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
    $phaseClock.Restart()
    & $deploy --verbose 0 --release --no-compiler-runtime --no-system-dxc-compiler --no-translations --dir $payload --plugindir "$payload\plugins" --qmldir $stage --qmlimport "$payload\qml" "$payload\qs.exe" 2>&1 | ForEach-Object { "$_" }
    $deployExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($deployExit -ne 0) { throw "windeployqt failed with exit code $deployExit" }
    $timings.deployQtSeconds = $phaseClock.Elapsed.TotalSeconds
    @('[Paths]', 'Prefix=.', 'Plugins=plugins', 'QmlImports=qml') | Set-Content -LiteralPath "$payload\qt.conf" -Encoding ASCII
    # install.json is written last: a staging directory without it is not an install.
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix; profile = $ProfileRoot
        installId = $installId
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        backendRevision = $(if ($buildInfo) { $buildInfo.backendRevision } else { '' })
        glazierRevision = $(if ($buildInfo) { [string]$buildInfo.glazierRevision } else { '' })
        captureSourcePath = $(if ($buildInfo) { [string]$buildInfo.captureSourcePath } else { '' })
        captureSourceRevision = $(if ($buildInfo) { [string]$buildInfo.captureSourceRevision } else { '' })
        captureOriginRevision = $(if ($buildInfo) { [string]$buildInfo.captureOriginRevision } else { '' })
        captureCargoLockSha256 = $(if ($buildInfo) { [string]$buildInfo.captureCargoLockSha256 } else { '' })
        captureExecutable = 'caelestia-capture.exe'
        executableSha256 = (Get-FileHash -LiteralPath "$payload\qs.exe").Hash
        captureSha256 = (Get-FileHash -LiteralPath "$payload\caelestia-capture.exe").Hash.ToLowerInvariant()
        glazierSha256 = (Get-FileHash -LiteralPath "$payload\caelestia-capture.exe").Hash
    } | ConvertTo-Json | Set-Content -LiteralPath "$payload\install.json" -Encoding UTF8
    Remove-Item -LiteralPath "$payload\.caelestia-staging.json" -Force -ErrorAction SilentlyContinue

    Write-CaelestiaProfileOwner $ProfileRoot $Prefix $installId $profileExclusive
    Write-Output ('Payload assembled in {0:N2}s.' -f $preparation.Elapsed.TotalSeconds)
    $timings.payloadAssemblySeconds = $preparation.Elapsed.TotalSeconds
    # Prepare the optional scheme runtime here, while the previous shell still
    # serves the desktop. Activation then only starts the shell; a cold venv or
    # slow network cannot consume its readiness budget or cause a rollback.
    # This phase never fails the install: the shell keeps its fixed palette.
    if (-not $SkipSchemeRuntime) {
        $scheme = Install-CaelestiaSchemeRuntime $payload $ProfileRoot
        if ($scheme.available) {
            Write-Output ('Scheme runtime prepared in {0:N2}s.' -f $scheme.seconds)
        } else {
            Write-Warning 'Scheme runtime was not prepared; Caelestia will start with its fixed palette. The install continues; see scheme\provision.log and provision-state.json, then retry with Install-SchemeRuntime.ps1.'
        }
    }
    $phaseClock.Restart()
    $runtimePrefix = Install-CaelestiaVersion $Prefix $payload -Restart:$Restart
    $timings.versionSelectionSeconds = $phaseClock.Elapsed.TotalSeconds
    # Pruning is deferred while any shell or supervisor can still be using a
    # generation; the next install without a live shell removes the rest.
    Remove-CaelestiaSchemeGenerations $Prefix $ProfileRoot
    # Integration belongs to the activation transaction: if it cannot be
    # written, the activation is rolled back instead of leaving a selector that
    # claims a replacement the caller was told failed.
    $installed = Read-CaelestiaInstall $Prefix
    if (-not $NoIntegration) {
        Complete-CaelestiaInstallIntegration $Prefix $runtimePrefix -Previous ([string]$installed.previous) -Restart:$Restart -Autostart:$Autostart
    }
    Remove-CaelestiaRetiredVersions $Prefix
    $launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
    Write-Output "Installed Caelestia: $Prefix"
    Write-Output "Run: powershell -NoProfile -File `"$launcher`""
    Write-Output "Profile (seeded on first launch): $ProfileRoot"
    if ($TimingFile) { $timings | ConvertTo-Json | Set-Content -LiteralPath $TimingFile -Encoding UTF8 }
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
