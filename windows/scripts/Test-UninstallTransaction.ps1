[CmdletBinding()]
param(
    [string]$OutputRoot,
    # Negative control: read only this revision's uninstall into the sandbox.
    [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$UninstallSourceRevision = '',
    [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$ManageSourceRevision = '',
    [switch]$StaleReadOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if (-not $OutputRoot) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-uninstall-transaction-' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = Resolve-CaelestiaDirectory $OutputRoot
if (Test-Path -LiteralPath $OutputRoot) {
    Assert-CaelestiaNoReparsePoints $OutputRoot
    $marker = Join-Path $OutputRoot '.erm629-fixture-owner'
    if (-not (Test-Path -LiteralPath $marker) -or
        [IO.File]::ReadAllText($marker) -ne 'caelestia-uninstall-transaction-v1') {
        throw 'Output directory exists without this fixture ownership marker.'
    }
} else {
    [IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $OutputRoot '.erm629-fixture-owner'), 'caelestia-uninstall-transaction-v1')
}
$runRoot = Join-Path $OutputRoot ('run-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
$script:assertions = 0
$script:children = @()
$script:scenarios = @()
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repoRoot 'windows\capture\Source.ps1')
$captureSource = Get-CaelestiaCaptureSource $repoRoot
$revision = (& git -C $repoRoot rev-parse HEAD).Trim()
$uninstallText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1'))
$manageText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Manage-Caelestia.ps1'))
if ($UninstallSourceRevision) {
    $uninstallText = (& git -C $repoRoot show "${UninstallSourceRevision}:windows/scripts/Uninstall-Caelestia.ps1") -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read negative-control revision.' }
}
if ($ManageSourceRevision) {
    $manageText = (& git -C $repoRoot show "${ManageSourceRevision}:windows/scripts/Manage-Caelestia.ps1") -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read negative-control Manage revision.' }
}
$boundary = Join-Path $PSScriptRoot 'UninstallTransaction-FixtureBoundary.ps1'
$importBoundary = "`r`n. '" + $boundary.Replace("'", "''") + "'"
function Assert($Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Replace-Exactly([string]$Text, [string]$Old, [string]$New) {
    if ([regex]::Matches($Text, [regex]::Escape($Old)).Count -ne 1) { throw 'Fixture injection boundary changed; refusing to run.' }
    return $Text.Replace($Old, $New)
}
function Write-FixtureText([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function New-Case([string]$Name, [switch]$RealIntegration) {
    $case = Join-Path $runRoot $Name
    $prefix = Join-Path $case 'prefix'
    $profile = Join-Path $case 'profile'
    $scripts = Join-Path $case 'scripts'
    [IO.Directory]::CreateDirectory($scripts) | Out-Null
    foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1',
        'Switch-CaelestiaToWindows.ps1', 'Caelestia-Launcher.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts
    }
    foreach ($name in @('Caelestia-SemVer.ps1', 'Caelestia-UpdateTrust.ps1', 'Caelestia-Update.ps1', 'Caelestia-UpdateSecurity.cs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts
    }
    $import = ". (Join-Path `$PSScriptRoot 'Caelestia-InstallCommon.ps1')"
    $manage = Replace-Exactly $manageText $import ($import + $importBoundary + "`r`nInvoke-FixtureBoundary 'entry'")
    # Pause after the real mutable read, not a fabricated selector. Old Manage
    # read before locking; the changed path reads only after acquiring.
    $manage = $manage.Replace('$record = Read-CaelestiaInstall $Prefix',
        "`$record = Read-CaelestiaInstall `$Prefix`r`nInvoke-FixtureBoundary 'record-read'")
    Write-FixtureText (Join-Path $scripts 'Manage-Caelestia.ps1') $manage
    $sourceInstall = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install-Caelestia.ps1'))
    Write-FixtureText (Join-Path $scripts 'Install-Caelestia.ps1') (Replace-Exactly $sourceInstall $import ($import + $importBoundary))
    $fixtureCapture = Join-Path $case 'source-repo\windows\capture'
    [IO.Directory]::CreateDirectory($fixtureCapture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\capture\Source.ps1') -Destination $fixtureCapture
    # Source installer preflight runs against data-only prerequisites. Tests
    # either refuse busy, or throw at its first post-lock external boundary,
    # before assembly, deployment or compilation can execute.
    foreach ($relative in @('source-build\quickshell\qs.exe', 'source-build\install\caelestia-capture.exe',
        'source-build\install\qml\Caelestia\Windows\qmldir', 'source-build\install\qml\M3Shapes\qmldir',
        'source-qt\bin\windeployqt.exe', 'source-crt\msvcp140.dll',
        'source-crt\vcruntime140.dll', 'source-crt\vcruntime140_1.dll', 'source-repo\fixture.txt')) {
        Write-FixtureText (Join-Path $case $relative) 'synthetic prerequisite; never execute'
    }
    [IO.Directory]::CreateDirectory((Join-Path $case 'tasks')) | Out-Null
    $uninstall = Replace-Exactly $uninstallText $import ($import + $importBoundary)
    # By default the boundary replaces the single integration cleanup function,
    # so the real uninstall reaches no registry key, Start-menu directory or COM
    # shortcut. The two integration-failure cases switch the boundary to real
    # cleanup against disposable files and HKCU test roots only.
    Write-FixtureText (Join-Path $scripts 'Uninstall-Caelestia.ps1') $uninstall
    $launcher = @'
param($Prefix, $Command = 'Start', [switch]$PreparedSchemeRuntime)
if ($Prefix -ne $env:CAELESTIA_FIXTURE_PREFIX -or $Command -ne 'Quit') { throw 'Blocked unexpected fixture launcher command.' }
Add-Content -LiteralPath (Join-Path $env:CAELESTIA_FIXTURE_CONTROL 'boundaries.txt') -Value 'quit'
'@
    # A complete synthetic release passes the REAL manifest/path/hash verifier.
    # Its EXE/DLL files are data only; launch/task boundaries above never run them.
    $bundle = Join-Path $case 'bundle'
    $required = @(
        'Install.cmd', 'Install-CaelestiaRelease.ps1', 'INSTALL-RELEASE.md',
        'payload/qs.exe', 'payload/glazier.exe', 'payload/qt.conf',
        'payload/Qt6Core.dll', 'payload/Qt6Qml.dll', 'payload/Qt6Quick.dll',
        'payload/plugins/platforms/qwindows.dll', 'payload/qml/Caelestia/Windows/qmldir',
        'payload/qml/M3Shapes/qmldir', 'payload/m3shapes.dll', 'payload/shell/shell.qml',
        'payload/shell/sources.json', 'payload/defaults/shell.json', 'payload/defaults/windows.json',
        'payload/defaults/keybinds.json', 'payload/DesktopTakeover.dll', 'payload/DesktopTakeover.build.json',
        'payload/Start-Caelestia.ps1', 'payload/Start-CaelestiaEntry.ps1',
        'payload/Manage-Caelestia.ps1', 'payload/Uninstall-Caelestia.ps1',
        'payload/Caelestia-InstallCommon.ps1', 'payload/Caelestia-Versions.ps1',
        'payload/Switch-CaelestiaToWindows.ps1', 'payload/Caelestia-Launcher.ps1',
        'payload/Caelestia-SemVer.ps1', 'payload/Caelestia-Update.ps1',
        'payload/Caelestia-UpdateTrust.ps1', 'payload/Caelestia-UpdateSecurity.cs',
        'payload/Start-DesktopShell.ps1', 'payload/Watch-DesktopShell.ps1', 'payload/Restore-Desktop.ps1',
        'payload/Install-SchemeRuntime.ps1', 'payload/Get-AccountPicture.ps1', 'payload/Banner-Suppression.ps1',
        'payload/scheme/requirements.lock.txt', 'payload/scheme/win_scheme.py', 'payload/scheme/fcntl.py',
        'payload/licenses/LICENSE', 'payload/licenses/THIRD-PARTY-NOTICES.md',
        'payload/licenses/sources.lock.json', 'payload/licenses/Glazier-LICENSE',
        'payload/licenses/Glazier-THIRD_PARTY_NOTICES.md', 'payload/licenses/M3Shapes-LICENSE',
        'payload/licenses/Quickshell-LICENSE', 'payload/licenses/Qt/LGPL-3.0.txt'
    )
    foreach ($relative in $required) { Write-FixtureText (Join-Path $bundle $relative) 'synthetic fixture data' }
    foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1',
        'Switch-CaelestiaToWindows.ps1', 'Caelestia-Launcher.ps1',
        'Caelestia-SemVer.ps1', 'Caelestia-UpdateTrust.ps1', 'Caelestia-Update.ps1', 'Caelestia-UpdateSecurity.cs')) {
        Copy-Item -LiteralPath (Join-Path $scripts $name) -Destination (Join-Path $bundle "payload\$name") -Force
    }
    foreach ($name in @('Start-Caelestia.ps1', 'Start-CaelestiaEntry.ps1')) {
        Write-FixtureText (Join-Path $bundle "payload\$name") $launcher
    }
    $releaseScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'))
    $releaseImport = ". (Join-Path `$payloadSource 'Caelestia-InstallCommon.ps1')"
    $releaseScript = Replace-Exactly $releaseScript $releaseImport ($releaseImport + $importBoundary)
    # This copy installs inert data through mocked launch/integration boundaries,
    # including on Server 2022 CI. It does not qualify the real Windows 11 app.
    # Keep the native Windows/x64 checks; exclude only the app's OS-build floor.
    $releaseScript = Replace-Exactly $releaseScript `
        'if ([Environment]::OSVersion.Version.Build -lt 22000) {' 'if ($false) {'
    # The machine's VC runtime is not a prerequisite for data-only fixtures.
    $releaseScript = Replace-Exactly $releaseScript `
        'if (-not (Test-ReleaseVCRuntime ([version]$release.prerequisites.visualCppRuntime.minimumVersion))) {' `
        'if (-not ($true)) {'
    Write-FixtureText (Join-Path $bundle 'Install-CaelestiaRelease.ps1') $releaseScript
    $header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    Write-FixtureText (Join-Path $bundle 'payload\shell\shell.qml') ($header + 'fixture')
    Write-FixtureText (Join-Path $bundle 'payload\shell\sources.json') '[{"staged":"shell.qml","stagedSha256":"fixture"}]'
    $backend = 'e6039b2b9cbb35b97473bda4dcc3f12789ae7f0c'
    $files = foreach ($relative in $required) {
        $path = Join-Path $bundle $relative
        @{ path = $relative; size = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path).Hash }
    }
    $manifest = @{
        schema = 'caelestia-windows-release'; version = 1; platform = 'windows-x64'
        sourceRevision = $revision; nativeSourceRevision = $revision; backendRevision = $backend
        releaseId = 'uninstall-fixture'; relocation = 'profile-pragmas-v1'; files = @($files)
        dependencies = @{
            quickshell = @{ revision = $backend }
            glazier = @{ revision = '37f795041cbbb32ed46cba103f3f000a3a99ac13' }
            m3shapes = @{ revision = '32ad9ce328bb77ed349b40a3be10ee9ea610b8ab' }
        }
        prerequisites = @{ visualCppRuntime = @{
            deployment = 'system'; architecture = 'x64'; minimumVersion = '14.44.35211.0'
            downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
        } }
    }
    Write-FixtureText (Join-Path $bundle 'release.json') ($manifest | ConvertTo-Json -Depth 10)
    # Two disposable valid retained versions, not a live installation.
    foreach ($id in @('v1', 'v2')) {
        $runtime = Join-Path $prefix "versions\$id"
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1',
            'Switch-CaelestiaToWindows.ps1', 'Caelestia-Launcher.ps1',
            'Caelestia-SemVer.ps1', 'Caelestia-UpdateTrust.ps1', 'Caelestia-Update.ps1', 'Caelestia-UpdateSecurity.cs')) {
            Copy-Item -LiteralPath (Join-Path $scripts $name) -Destination $runtime
        }
        Write-FixtureText (Join-Path $runtime 'Start-CaelestiaEntry.ps1') $launcher
        Write-FixtureText (Join-Path $runtime 'Start-Caelestia.ps1') $launcher
        Write-FixtureText (Join-Path $runtime 'qs.exe') $id
        $record = @{
            product = 'caelestia-windows'; version = 1; prefix = $runtime; installRoot = $prefix; versionId = $id
            profile = $profile; installId = 'erm629-fixture'; sourceRevision = $revision
            executableSha256 = (Get-FileHash -LiteralPath (Join-Path $runtime 'qs.exe')).Hash
        }
        Write-FixtureText (Join-Path $runtime 'install.json') ($record | ConvertTo-Json)
    }
    $current = Read-CaelestiaInstall (Join-Path $prefix 'versions\v2')
    Write-CaelestiaJsonAtomic (Join-Path $prefix 'install.json') (New-CaelestiaRootRecord $prefix $current 'v1')
    Copy-CaelestiaRootEntries $prefix (Join-Path $prefix 'versions\v2')
    Write-CaelestiaProfileOwner $profile $prefix 'erm629-fixture' $true
    Write-FixtureText (Join-Path $profile 'config\sentinel.txt') 'owned profile content'
    Write-FixtureText (Join-Path $profile 'state\update-operation.json') '{"schema":1,"phase":"fixture"}'
    Write-FixtureText (Join-Path $case 'unrelated-profile\sentinel.txt') 'unrelated profile content'
    # Prefix-derived per-user entries, simulated as data. The fixture boundary
    # proves the real uninstall calls the single integration cleanup, and
    # Assert-Uninstalled proves this whole directory is emptied. The real-
    # integration cases use only the three shortcut files and a disposable HKCU
    # root, so the production cleanup and its snapshot/restore run unchanged.
    if (-not $RealIntegration) {
        Write-FixtureText (Join-Path $case 'integration\fixture-run') 'owned run value'
        Write-FixtureText (Join-Path $case 'integration\apps-features.json') 'owned Apps & features entry'
    }
    Write-FixtureText (Join-Path $case 'integration\shortcut.lnk') 'owned shortcut'
    Write-FixtureText (Join-Path $case 'integration\switch-back.lnk') 'owned switch-back shortcut'
    Write-FixtureText (Join-Path $case 'integration\desktop.lnk') 'owned desktop shortcut'
    return $case
}
function Start-Worker([string]$Case, [string]$Operation, [string]$Pause = '', [bool]$Purge = $false,
    [bool]$KeepAlive = $false, [bool]$ThrowAtBoundary = $false, [bool]$AliasPrefix = $false, [string]$OperationId = '',
    [switch]$RealIntegration, [string]$IntegrationFailure = '') {
    $control = Join-Path $Case ('control-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($control) | Out-Null
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        (Join-Path $PSScriptRoot 'Invoke-UninstallTransactionFixture.ps1') + '" -CaseRoot "' + $Case +
        '" -Control "' + $control + '" -Operation ' + $Operation
    if ($Pause) { $arguments += ' -Pause ' + $Pause }
    if ($Purge) { $arguments += ' -Purge' }
    if ($KeepAlive) { $arguments += ' -KeepAlive' }
    if ($ThrowAtBoundary) { $arguments += ' -ThrowAtBoundary' }
    if ($AliasPrefix) { $arguments += ' -AliasPrefix' }
    if ($OperationId) { $arguments += ' -OperationId ' + $OperationId }
    if ($RealIntegration) { $arguments += ' -RealIntegration' }
    if ($IntegrationFailure) { $arguments += ' -IntegrationFailure ' + $IntegrationFailure }
    $process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $arguments `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $control 'stdout.txt') `
        -RedirectStandardError (Join-Path $control 'stderr.txt')
    # Retain the handle before a fast busy refusal exits (Windows PS 5.1).
    $null = $process.Handle
    $worker = [pscustomobject]@{ Process = $process; Control = $control }
    $script:children += $worker
    return $worker
}
function Wait-Marker($Worker, [string]$Name) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $path = Join-Path $Worker.Control $Name
    while (-not (Test-Path -LiteralPath $path)) {
        if ($Worker.Process.HasExited -or $clock.Elapsed.TotalSeconds -gt 30) {
            $detail = ''
            $resultPath = Join-Path $Worker.Control 'result.json'
            if (Test-Path -LiteralPath $resultPath) {
                try {
                    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
                    $reason = Protect-CaelestiaText ([string]$result.message)
                    if ($reason.Length -gt 512) { $reason = $reason.Substring(0, 512) }
                    $detail = " Result $($result.status): $reason"
                } catch { $detail = ' Saved worker result is unreadable.' }
            }
            throw "Worker failed before $Name.$detail Inspect local worker diagnostics."
        }
        Start-Sleep -Milliseconds 20
    }
}
function Release-Worker($Worker) { [IO.File]::WriteAllText((Join-Path $Worker.Control 'release'), 'release') }
function Finish-Worker($Worker) {
    [IO.File]::WriteAllText((Join-Path $Worker.Control 'finish'), 'finish')
    Assert ($Worker.Process.WaitForExit(10000)) 'Worker did not exit.'
    Assert ($Worker.Process.ExitCode -eq 0) "Worker returned a failing exit code: $($Worker.Process.ExitCode)."
}
function Assert-Result($Worker, [string]$Expected) {
    Wait-Marker $Worker 'result.json'
    $result = Get-Content -LiteralPath (Join-Path $Worker.Control 'result.json') -Raw | ConvertFrom-Json
    Assert ($result.status -eq $Expected) "Expected $Expected, got $($result.status): $($result.message)"
}
function Read-Result($Worker) {
    Wait-Marker $Worker 'result.json'
    return Get-Content -LiteralPath (Join-Path $Worker.Control 'result.json') -Raw | ConvertFrom-Json
}
function Finish-ErrorWorker($Worker) {
    Assert-Result $Worker 'Error'
    [IO.File]::WriteAllText((Join-Path $Worker.Control 'finish'), 'finish')
    Assert ($Worker.Process.WaitForExit(10000)) 'Refused worker did not exit.'
    Assert ($Worker.Process.ExitCode -eq 1) 'Expected refusal exit code.'
}
function Start-QueuedOperation([string]$Case) {
    $queue = Start-Worker $Case 'Queue'
    Assert-Result $queue 'Success'
    $id = (Read-Result $queue).operationId
    Assert ($id -match '^[a-f0-9]{32}$') 'Queue did not return its tracked operation.'
    Finish-Worker $queue
    return $id
}
function Snapshot([string]$Case) {
    $lines = foreach ($tree in @('prefix', 'profile', 'integration', 'unrelated-profile', 'tasks')) {
        $path = Join-Path $Case $tree
        if (-not (Test-Path -LiteralPath $path)) { "$tree ABSENT"; continue }
        $tree
        foreach ($item in Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName) {
            $relative = $item.FullName.Substring($Case.Length + 1)
            if ($item.PSIsContainer) { $relative + ' DIRECTORY' }
            else { $relative + ' ' + (Get-FileHash -LiteralPath $item.FullName).Hash }
        }
    }
    # Staging/tombstone siblings are transaction state too, not invisible
    # leftovers outside the prefix snapshot.
    $lines += foreach ($item in Get-ChildItem -LiteralPath $Case -Force |
        Where-Object { $_.Name -like 'prefix.staging-*' -or $_.Name -like 'prefix.uninstall-*' } | Sort-Object Name) {
        $item.Name
        foreach ($file in Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force | Sort-Object FullName) {
            $file.FullName.Substring($Case.Length + 1) + ' ' + (Get-FileHash -LiteralPath $file.FullName).Hash
        }
    }
    return $lines -join "`n"
}
function Assert-Coherent([string]$Case) {
    $prefix = Join-Path $Case 'prefix'
    $record = Read-CaelestiaInstall $prefix
    Assert ($record.version -eq 2) 'Versioned selector missing.'
    Assert (Test-CaelestiaVersionPayload $prefix $record.current) 'Selected payload is not coherent.'
    Assert (Test-CaelestiaVersionPayload $prefix $record.previous) 'Previous payload is not coherent.'
    Assert ((Read-CaelestiaProfileOwner (Join-Path $Case 'profile')).installId -eq $record.installId) 'Profile owner changed.'
    Assert (@(Get-ChildItem -LiteralPath $Case -Directory -Filter 'prefix.staging-*').Count -eq 0) 'Staging sibling was left behind.'
    # Install and rollback must leave the prefix-derived integration entries
    # alone. The uninstall scenarios then prove they are really removed.
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $Case 'integration') -Force).Count -eq 5) 'A non-uninstall transaction changed the integration fixture.'
}
function Assert-Uninstalled([string]$Case, [bool]$Purge) {
    Assert (-not (Test-Path -LiteralPath (Join-Path $Case 'prefix'))) 'Prefix not removed.'
    Assert (@(Get-ChildItem -LiteralPath $Case -Directory -Filter 'prefix.uninstall-*').Count -eq 0) 'Tombstone not cleaned.'
    Assert (@(Get-ChildItem -LiteralPath $Case -Directory -Filter 'prefix.staging-*').Count -eq 0) 'Staging sibling was left behind.'
    $ownedTasks = @(foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Case 'tasks') -File) {
        $task = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if (@($task.Actions | Where-Object { $_.WorkingDirectory -eq (Join-Path $Case 'prefix') }).Count) { $task }
    })
    Assert ($ownedTasks.Count -eq 0) 'Owned maintenance tasks were left behind.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $Case 'integration') -Force).Count -eq 0) 'Integration not removed.'
    Assert ((Test-Path -LiteralPath (Join-Path $Case 'profile')) -eq (-not $Purge)) 'Purge/profile preservation mismatch.'
    if (-not $Purge) {
        Assert ([IO.File]::ReadAllText((Join-Path $Case 'profile\config\sentinel.txt')) -eq 'owned profile content') 'Kept profile modified.'
    }
    Assert ([IO.File]::ReadAllText((Join-Path $Case 'unrelated-profile\sentinel.txt')) -eq 'unrelated profile content') 'Unrelated profile modified.'
}
# The real-integration cases use disposable files and an HKCU test root whose
# name is derived from the case path, exactly as the fixture worker derives it.
function Get-IntegrationRegistryRoot([string]$Case) {
    return 'HKCU:\Software\CaelestiaWindowsTests\' + (Get-CaelestiaInstallLockKey $Case).Substring(0, 16)
}
function Initialize-RealIntegration([string]$Case, [string]$Root) {
    $runKey = $Root + '\Run'
    $appsKey = $Root + '\Uninstall\fixture-apps'
    New-CaelestiaRegistryKey $runKey
    New-ItemProperty -Path $runKey -Name 'fixture-run' -PropertyType String `
        -Value '"C:\Windows\System32\wscript.exe" //B //Nologo "C:\old\Caelestia-Launcher.vbs" start "C:\old"' -Force | Out-Null
    New-CaelestiaRegistryKey $appsKey
    foreach ($pair in @(
        @('DisplayName', 'Caelestia for Windows'), @('DisplayVersion', '1.0.0'),
        @('Publisher', 'KldsSeeGhosts'), @('UninstallString', '"C:\old" uninstall')
    )) {
        New-ItemProperty -Path $appsKey -Name $pair[0] -PropertyType String -Value $pair[1] -Force | Out-Null
    }
}
function Get-IntegrationRegistryState([string]$Root) {
    $lines = @()
    foreach ($path in @($Root + '\Run', $Root + '\Uninstall\fixture-apps')) {
        if (-not (Test-Path -LiteralPath $path)) { $lines += "$path ABSENT"; continue }
        $lines += $path
        $key = Get-Item -LiteralPath $path
        foreach ($name in @($key.GetValueNames() | Sort-Object)) {
            $lines += $name + '=' + [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
    return $lines -join "`n"
}
$passed = $false
$failure = ''
$failureLine = $null
$failureCase = $null
try {
    if (-not $StaleReadOnly) {
    foreach ($recovery in @('orphan-queued', 'dead-working', 'expired-queued', 'legacy-queued', 'foreign-task')) {
        $case = New-Case "queue-recovery-$recovery"
        $oldId = Start-QueuedOperation $case
        $journalPath = Join-Path $case 'profile\state\update-operation.json'
        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $oldTaskPaths = @(
            (Join-Path $case "tasks\Caelestia-Maintenance-$oldId.json"),
            (Join-Path $case "tasks\Caelestia-MaintenanceWatch-$oldId.json"))
        $foreignBefore = ''
        if ($recovery -eq 'orphan-queued') {
            foreach ($path in $oldTaskPaths) { Remove-Item -LiteralPath $path }
        } elseif ($recovery -eq 'dead-working') {
            # No worker owns the lock. The registered records must not make a
            # dead 'working' journal permanently block later requests.
            $journal.phase = 'working'
        } elseif ($recovery -eq 'expired-queued') {
            $journal | Add-Member -NotePropertyName queuedDeadlineUtc -NotePropertyValue ([DateTime]::UtcNow.AddSeconds(-1).ToString('o')) -Force
        } elseif ($recovery -eq 'legacy-queued') {
            $journal.PSObject.Properties.Remove('queuedDeadlineUtc')
        } else {
            foreach ($path in $oldTaskPaths) {
                $task = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                $task.Actions[0].WorkingDirectory = Join-Path $case 'unrelated-prefix'
                Write-FixtureText $path ($task | ConvertTo-Json -Depth 6)
            }
            $foreignBefore = ($oldTaskPaths | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
        }
        Write-FixtureText $journalPath ($journal | ConvertTo-Json)
        $newId = Start-QueuedOperation $case
        Assert ($newId -ne $oldId) 'Stale request did not receive a new fenced identity.'
        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        Assert ($journal.operationId -eq $newId -and $journal.phase -eq 'queued') 'Recovered queue did not publish its new identity.'
        Assert ([DateTime]::Parse($journal.queuedDeadlineUtc).ToUniversalTime() -gt [DateTime]::UtcNow) 'Queue has no future deadline.'
        if ($recovery -eq 'foreign-task') {
            Assert ((($oldTaskPaths | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n") -ceq $foreignBefore) 'Queue recovery changed foreign-prefix tasks.'
        } else {
            foreach ($path in $oldTaskPaths) { Assert (-not (Test-Path -LiteralPath $path)) 'Stale request left an owned task behind.' }
        }
        $before = Snapshot $case
        $late = Start-Worker $case 'TrackedRollback' -OperationId $oldId
        Finish-ErrorWorker $late
        Assert ((Snapshot $case) -ceq $before) 'Fenced old worker changed the new operation or installation.'
        Assert-Coherent $case
        $script:scenarios += "queue-recovery-$recovery"
    }
    $case = New-Case 'live-queued-request-refused'
    $id = Start-QueuedOperation $case
    $before = Snapshot $case
    $duplicate = Start-Worker $case 'Queue'
    Assert-Result $duplicate 'Busy'
    Finish-Worker $duplicate
    Assert ((Snapshot $case) -ceq $before) 'Live queued duplicate changed managed state.'
    $script:scenarios += 'live-queued-request-refused'

    $case = New-Case 'malformed-journal-uninstall'
    Write-FixtureText (Join-Path $case 'profile\state\update-operation.json') '{invalid'
    $uninstall = Start-Worker $case 'Uninstall'
    Assert-Result $uninstall 'Success'
    Finish-Worker $uninstall
    Assert-Uninstalled $case $false
    $script:scenarios += 'malformed-journal-uninstall'

    $case = New-Case 'malformed-journal-maintenance-refusal'
    Write-FixtureText (Join-Path $case 'profile\state\update-operation.json') '{invalid'
    $before = Snapshot $case
    $queue = Start-Worker $case 'Queue'
    Finish-ErrorWorker $queue
    Assert ((Snapshot $case) -ceq $before) 'Unreadable journal refusal changed managed state.'
    Assert-Coherent $case
    $script:scenarios += 'malformed-journal-maintenance-refusal'

    foreach ($purge in @($false, $true)) {
        foreach ($operation in @('Install', 'Rollback')) {
            $name = "held-$operation-purge-$purge"
            $case = New-Case $name
            $pause = if ($operation -eq 'Install') { 'processes' } else { 'scheme' }
            $owner = Start-Worker $case $operation $pause
            Wait-Marker $owner 'ready'
            $before = Snapshot $case
            $contender = Start-Worker $case 'Uninstall' '' $purge $false $false $true
            Assert-Result $contender 'Busy'
            Finish-Worker $contender
            Assert ((Snapshot $case) -ceq $before) 'Busy uninstall mutated prefix, profile or integration.'
            Release-Worker $owner
            Assert-Result $owner 'Success'
            Finish-Worker $owner
            Assert-Coherent $case
            if ($operation -eq 'Rollback') {
                Assert ((Read-CaelestiaInstall (Join-Path $case 'prefix')).current -eq 'v1') 'Real rollback selector did not change.'
            } else {
                Assert ((Read-CaelestiaInstall (Join-Path $case 'prefix')).current -notin @('v1', 'v2')) 'Real release install did not publish a payload.'
            }
            $uninstall = Start-Worker $case 'Uninstall' '' $purge $true
            Assert-Result $uninstall 'Success'
            Assert-Uninstalled $case $purge
            # A new real installation succeeds while successful uninstall's
            # process is still alive, proving release was finally, not exit.
            $probe = Start-Worker $case 'Install'
            Assert-Result $probe 'Success'
            Finish-Worker $probe
            Finish-Worker $uninstall
            $script:scenarios += $name
        }
        foreach ($operation in @('Install', 'Rollback', 'SourceInstall', 'Queue')) {
            $name = "held-Uninstall-vs-$operation-purge-$purge"
            $case = New-Case $name
            $owner = Start-Worker $case 'Uninstall' 'integration' $purge $true
            Wait-Marker $owner 'ready'
            $before = Snapshot $case
            $contender = Start-Worker $case $operation
            Assert-Result $contender 'Busy'
            Finish-Worker $contender
            Assert ((Snapshot $case) -ceq $before) 'Busy transaction mutated managed data, journal, tasks or integration.'
            Release-Worker $owner
            Assert-Result $owner 'Success'
            Assert-Uninstalled $case $purge
            Finish-Worker $owner
            $script:scenarios += $name
        }
        foreach ($operation in @('Install', 'Rollback', 'Uninstall')) {
            $name = "abandoned-$operation-purge-$purge"
            $case = New-Case $name
            $pause = switch ($operation) { Install { 'processes' } Rollback { 'scheme' } Uninstall { 'integration' } }
            $owner = Start-Worker $case $operation $pause $purge
            Wait-Marker $owner 'ready'
            # Keep kernel objects alive after termination, so the next real
            # operation encounters abandoned ownership, not a fresh mutex.
            $key = Get-CaelestiaInstallLockKey (Join-Path $case 'prefix')
            $globalObserver = [Threading.Mutex]::OpenExisting('Global\CaelestiaInstall-' + $key)
            $localObserver = [Threading.Mutex]::OpenExisting('Local\CaelestiaInstall-' + $key)
            try {
                $before = Snapshot $case
                $owner.Process.Kill()
                Assert ($owner.Process.WaitForExit(10000)) 'Interrupted fixture owner did not exit.'
                Assert ((Snapshot $case) -ceq $before) 'Interrupted boundary mutated managed state.'
                Assert-Coherent $case
                $next = Start-Worker $case 'Uninstall' '' $purge
                Assert-Result $next 'Success'
                Finish-Worker $next
                Assert-Uninstalled $case $purge
            } finally {
                $localObserver.Dispose()
                $globalObserver.Dispose()
            }
            $script:scenarios += $name
        }
        $name = "exception-release-purge-$purge"
        $case = New-Case $name
        $before = Snapshot $case
        $owner = Start-Worker $case 'Uninstall' 'integration' $purge $true $true
        Wait-Marker $owner 'ready'
        Release-Worker $owner
        Assert-Result $owner 'Injected'
        Assert ((Snapshot $case) -ceq $before) 'Injected pre-mutation exception changed managed state.'
        $next = Start-Worker $case 'Rollback'
        Assert-Result $next 'Success'
        Finish-Worker $next
        Assert-Coherent $case
        Finish-Worker $owner
        $script:scenarios += $name
    }

    # An integration-cleanup failure must not strand the uninstall after the
    # prefix is gone. The real cleanup runs against disposable shortcut files
    # and a disposable HKCU root; a locked shortcut and a denied Apps & features
    # key removal each fail after the tombstone rename. Recovery must restore
    # the prefix and every owned entry byte-for-byte, and a retry must succeed.
    foreach ($failure in @('locked-shortcut', 'registry-denial')) {
        $name = "cleanup-failure-$failure"
        $case = New-Case $name -RealIntegration
        $registryRoot = Get-IntegrationRegistryRoot $case
        try {
            Initialize-RealIntegration $case $registryRoot
            $before = Snapshot $case
            $registryBefore = Get-IntegrationRegistryState $registryRoot
            $lock = $null
            if ($failure -eq 'locked-shortcut') {
                $lock = [IO.File]::Open((Join-Path $case 'integration\shortcut.lnk'),
                    [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
            try {
                $worker = Start-Worker $case 'Uninstall' '' $false $false $false $false '' `
                    -RealIntegration -IntegrationFailure $failure
                Assert-Result $worker 'Error'
                Finish-ErrorWorker $worker
            } finally {
                if ($lock) { $lock.Dispose() }
            }
            Assert ((Snapshot $case) -ceq $before) 'A failed cleanup changed the installation, left a tombstone or lost an entry.'
            Assert ((Get-IntegrationRegistryState $registryRoot) -ceq $registryBefore) 'A failed cleanup lost the Run value or the Apps & features entry.'
            Assert (@(Get-ChildItem -LiteralPath $case -Directory -Filter 'prefix.uninstall-*').Count -eq 0) 'A failed cleanup left its tombstone.'
            $retry = Start-Worker $case 'Uninstall' '' $false $false $false $false '' -RealIntegration
            Assert-Result $retry 'Success'
            Finish-Worker $retry
            Assert-Uninstalled $case $false
            Assert ($null -eq (Get-ItemProperty -LiteralPath ($registryRoot + '\Run') -Name 'fixture-run' -ErrorAction SilentlyContinue)) 'The retry left the Run value behind.'
            Assert (-not (Test-Path -LiteralPath ($registryRoot + '\Uninstall\fixture-apps'))) 'The retry left the Apps & features key behind.'
            $script:scenarios += $name
        } finally {
            if (Test-Path -LiteralPath $registryRoot) { Remove-Item -LiteralPath $registryRoot -Recurse -Force }
        }
    }
    $case = New-Case 'busy-before-manifest-read'
    $owner = Start-Worker $case 'Install' 'processes'
    Wait-Marker $owner 'ready'
    $manifestPath = Join-Path $case 'prefix\install.json'
    $saved = [IO.File]::ReadAllText($manifestPath)
    Write-FixtureText $manifestPath 'invalid mutable manifest'
    $before = Snapshot $case
    $next = Start-Worker $case 'Uninstall' '' $true
    Assert-Result $next 'Busy'
    Finish-Worker $next
    Assert ((Snapshot $case) -ceq $before) 'Busy uninstall read/mutated invalid mutable identity.'
    Write-FixtureText $manifestPath $saved
    Release-Worker $owner
    Assert-Result $owner 'Success'
    Finish-Worker $owner
    Assert-Coherent $case
    $script:scenarios += 'busy-before-manifest-read'

    $case = New-Case 'foreign-profile-purge-refusal'
    Write-CaelestiaProfileOwner (Join-Path $case 'profile') (Join-Path $case 'unrelated-prefix') 'foreign' $true
    $before = Snapshot $case
    $next = Start-Worker $case 'Uninstall' '' $true $true
    Assert-Result $next 'Error'
    Assert ((Snapshot $case) -ceq $before) 'Refused purge mutated managed state.'
    # Worker intentionally reports the production refusal as Error/exit 1.
    [IO.File]::WriteAllText((Join-Path $next.Control 'finish'), 'finish')
    Assert ($next.Process.WaitForExit(10000)) 'Refusal worker did not exit.'
    Assert ($next.Process.ExitCode -eq 1) 'Expected refusal exit code.'
    $script:scenarios += 'foreign-profile-purge-refusal'
    }
    $case = New-Case 'rollback-read-vs-purge'
    $owner = Start-Worker $case 'Rollback' 'record-read'
    Wait-Marker $owner 'ready'
    $before = Snapshot $case
    $purgeWorker = Start-Worker $case 'Uninstall' '' $true
    $purgeResult = Read-Result $purgeWorker
    if ($purgeResult.status -ne 'Busy') {
        # Negative control completes the stale read race, not merely its first
        # half: old Manage mkdirs/writes AFTER successful purge.
        Release-Worker $owner
        $null = Read-Result $owner
        $resurrected = Test-Path -LiteralPath (Join-Path $case 'profile')
        throw "Stale-read race: purge returned $($purgeResult.status); profile recreated=$resurrected."
    }
    Assert-Result $purgeWorker 'Busy'
    Finish-Worker $purgeWorker
    Assert ((Snapshot $case) -ceq $before) 'Purge changed a locked rollback snapshot.'
    Release-Worker $owner
    Assert-Result $owner 'Success'
    Finish-Worker $owner
    Assert-Coherent $case
    $script:scenarios += 'rollback-read-vs-purge'

    $case = New-Case 'purged-before-rollback-entry'
    $owner = Start-Worker $case 'Rollback' 'entry'
    Wait-Marker $owner 'ready'
    $purgeWorker = Start-Worker $case 'Uninstall' '' $true
    Assert-Result $purgeWorker 'Success'
    Finish-Worker $purgeWorker
    Assert-Uninstalled $case $true
    $before = Snapshot $case
    Release-Worker $owner
    Finish-ErrorWorker $owner
    foreach ($operation in @('Queue', 'TrackedRollback', 'Watch')) {
        $next = Start-Worker $case $operation -OperationId ('a' * 32)
        if ($operation -eq 'Watch') { Assert-Result $next 'Success'; Finish-Worker $next }
        else { Finish-ErrorWorker $next }
        Assert ((Snapshot $case) -ceq $before) 'Late maintenance recreated a purged profile or changed integration.'
    }
    $script:scenarios += 'purged-before-rollback-entry'

    if (-not $StaleReadOnly) {
    foreach ($failureMode in @('Success', 'Injected')) {
        $case = New-Case "direct-journal-free-$failureMode"
        $journalPath = Join-Path $case 'profile\state\update-operation.json'
        Remove-Item -LiteralPath $journalPath
        Remove-Item -LiteralPath (Join-Path $case 'profile\state')
        $pause = if ($failureMode -eq 'Injected') { 'scheme' } else { '' }
        $direct = Start-Worker $case 'Rollback' $pause -ThrowAtBoundary:($failureMode -eq 'Injected')
        if ($pause) { Wait-Marker $direct 'ready'; Release-Worker $direct }
        Assert-Result $direct $failureMode
        Finish-Worker $direct
        Assert (-not (Test-Path -LiteralPath (Join-Path $case 'profile\state'))) 'Untracked rollback created its journal directory.'
        Assert-Coherent $case
        $script:scenarios += "direct-journal-free-$failureMode"
    }
    foreach ($failureMode in @('Success', 'Injected')) {
        $case = New-Case "direct-preserves-journal-$failureMode"
        $journalPath = Join-Path $case 'profile\state\update-operation.json'
        $before = [IO.File]::ReadAllText($journalPath)
        $pause = if ($failureMode -eq 'Injected') { 'scheme' } else { '' }
        $direct = Start-Worker $case 'Rollback' $pause -ThrowAtBoundary:($failureMode -eq 'Injected')
        if ($pause) { Wait-Marker $direct 'ready'; Release-Worker $direct }
        Assert-Result $direct $failureMode
        Finish-Worker $direct
        Assert ([IO.File]::ReadAllText($journalPath) -ceq $before) 'Untracked rollback rewrote an existing operation journal.'
        Assert-Coherent $case
        $script:scenarios += "direct-preserves-journal-$failureMode"
    }

    $case = New-Case 'source-installer-held'
    $owner = Start-Worker $case 'SourceInstall' 'processes' -ThrowAtBoundary:$true
    Wait-Marker $owner 'ready'
    $before = Snapshot $case
    $next = Start-Worker $case 'Uninstall' '' $true
    Assert-Result $next 'Busy'
    Finish-Worker $next
    Assert ((Snapshot $case) -ceq $before) 'Busy uninstall changed source-installer transaction state.'
    Release-Worker $owner
    Assert-Result $owner 'Injected'
    Finish-Worker $owner
    Assert ((Snapshot $case) -ceq $before) 'Source installer crossed the injected pre-assembly boundary.'
    Assert-Coherent $case
    $script:scenarios += 'source-installer-held'

    $case = New-Case 'tracked-contention-watchdog'
    $id = Start-QueuedOperation $case
    $taskPath = Join-Path $case "tasks\Caelestia-MaintenanceWatch-$id.json"
    $task = Get-Content -LiteralPath $taskPath -Raw | ConvertFrom-Json
    Assert ($task.Settings.RestartCount -eq 3 -and $task.Settings.RestartIntervalSeconds -eq 60) 'Watchdog has no bounded contention retry policy.'
    Assert ($task.Settings.ExecutionTimeLimitSeconds -eq 30) 'Watchdog execution is unbounded.'
    $owner = Start-Worker $case 'SourceInstall' 'processes' -ThrowAtBoundary:$true
    Wait-Marker $owner 'ready'
    $before = Snapshot $case
    foreach ($operation in @('TrackedRollback', 'Watch', 'Queue')) {
        $next = Start-Worker $case $operation -OperationId $id
        Assert-Result $next 'Busy'
        Finish-Worker $next
        Assert ((Snapshot $case) -ceq $before) 'Tracked busy refusal changed bytes or removed its watchdog.'
    }
    Release-Worker $owner
    Assert-Result $owner 'Injected'
    Finish-Worker $owner
    $watch = Start-Worker $case 'Watch' -OperationId $id
    Assert-Result $watch 'Success'
    Finish-Worker $watch
    $journal = Get-Content -LiteralPath (Join-Path $case 'profile\state\update-operation.json') -Raw | ConvertFrom-Json
    Assert ($journal.operationId -eq $id -and $journal.phase -eq 'failed') 'Watchdog did not report its deferred failure after lock release.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $case 'tasks') -File).Count -eq 0) 'Watchdog did not clean its tasks.'
    $before = Snapshot $case
    $late = Start-Worker $case 'TrackedRollback' -OperationId $id
    Finish-ErrorWorker $late
    Assert ((Snapshot $case) -ceq $before) 'Late tracked worker overwrote a terminal operation.'
    Assert-Coherent $case
    $script:scenarios += 'tracked-contention-watchdog'

    foreach ($purge in @($false, $true)) {
        $case = New-Case "queued-vs-uninstall-purge-$purge"
        $queue = Start-Worker $case 'Queue' 'start-task'
        Wait-Marker $queue 'ready'
        # If queue still held its lock, this real source installer could not
        # reach process preflight. It throws there, before any assembly.
        $probe = Start-Worker $case 'SourceInstall' 'processes' -ThrowAtBoundary:$true
        Wait-Marker $probe 'ready'
        Release-Worker $probe
        Assert-Result $probe 'Injected'
        Finish-Worker $probe
        Release-Worker $queue
        Assert-Result $queue 'Success'
        $id = (Read-Result $queue).operationId
        Finish-Worker $queue
        $owner = Start-Worker $case 'Uninstall' 'integration' $purge -AliasPrefix:$true
        Wait-Marker $owner 'ready'
        $before = Snapshot $case
        foreach ($operation in @('TrackedRollback', 'Watch')) {
            $next = Start-Worker $case $operation -OperationId $id
            Assert-Result $next 'Busy'
            Finish-Worker $next
            Assert ((Snapshot $case) -ceq $before) 'Queued busy operation changed uninstall-owned data or tasks.'
        }
        Release-Worker $owner
        Assert-Result $owner 'Success'
        Finish-Worker $owner
        Assert-Uninstalled $case $purge
        $before = Snapshot $case
        $late = Start-Worker $case 'Watch' -OperationId $id
        Assert-Result $late 'Success'
        Finish-Worker $late
        Assert ((Snapshot $case) -ceq $before) 'Late watchdog resurrected cancelled installation/profile state.'
        $script:scenarios += "queued-vs-uninstall-purge-$purge"
    }
    foreach ($failureMode in @('Success', 'Injected')) {
        $case = New-Case "tracked-terminal-$failureMode"
        $id = Start-QueuedOperation $case
        $pause = if ($failureMode -eq 'Injected') { 'scheme' } else { '' }
        $worker = Start-Worker $case 'TrackedRollback' $pause -ThrowAtBoundary:($failureMode -eq 'Injected') -OperationId $id
        if ($pause) { Wait-Marker $worker 'ready'; Release-Worker $worker }
        Assert-Result $worker $failureMode
        Finish-Worker $worker
        $journal = Get-Content -LiteralPath (Join-Path $case 'profile\state\update-operation.json') -Raw | ConvertFrom-Json
        $phase = if ($failureMode -eq 'Success') { 'complete' } else { 'failed' }
        Assert ($journal.operationId -eq $id -and $journal.phase -eq $phase) 'Tracked terminal result is not truthful.'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $case 'tasks') -File).Count -eq 0) 'Tracked terminal result left tasks behind.'
        Assert-Coherent $case
        $script:scenarios += "tracked-terminal-$failureMode"
    }
    $case = New-Case 'foreign-task-preserved'
    $id = Start-QueuedOperation $case
    $taskPath = Join-Path $case "tasks\Caelestia-MaintenanceWatch-$id.json"
    $foreignTask = Get-Content -LiteralPath $taskPath -Raw | ConvertFrom-Json
    $foreignTask.Actions[0].WorkingDirectory = Join-Path $case 'unrelated-prefix'
    Write-FixtureText $taskPath ($foreignTask | ConvertTo-Json -Depth 6)
    $before = [IO.File]::ReadAllText($taskPath)
    $owner = Start-Worker $case 'Uninstall' '' $true
    Assert-Result $owner 'Success'
    Finish-Worker $owner
    Assert ([IO.File]::ReadAllText($taskPath) -ceq $before) 'Uninstall touched a task belonging to another prefix.'
    Assert-Uninstalled $case $true
    $script:scenarios += 'foreign-task-preserved'
    $case = New-Case 'interrupted-queue-orphan-watchdog'
    $owner = Start-Worker $case 'Queue' 'after-register-task'
    Wait-Marker $owner 'ready'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $case 'tasks') -File).Count -eq 1) 'Queue did not reach its pre-journal watchdog registration window.'
    $before = Snapshot $case
    $next = Start-Worker $case 'Uninstall' '' $true
    Assert-Result $next 'Busy'
    Finish-Worker $next
    Assert ((Snapshot $case) -ceq $before) 'Busy uninstall changed interrupted queue state.'
    $owner.Process.Kill()
    Assert ($owner.Process.WaitForExit(10000)) 'Queue owner did not exit.'
    $retry = Start-Worker $case 'Uninstall' '' $true
    Assert-Result $retry 'Success'
    Finish-Worker $retry
    Assert-Uninstalled $case $true
    $script:scenarios += 'interrupted-queue-orphan-watchdog'
    foreach ($interrupted in @($false, $true)) {
        $case = New-Case "post-rename-interrupted-$interrupted"
        $prefix = Join-Path $case 'prefix'
        $owner = Start-Worker $case 'Uninstall' 'remove-integration' $true $true (-not $interrupted)
        Wait-Marker $owner 'ready'
        Assert (-not (Test-Path -LiteralPath $prefix)) 'Post-rename boundary did not execute after the real rename.'
        $tombstones = @(Get-ChildItem -LiteralPath $case -Directory -Filter 'prefix.uninstall-*')
        Assert ($tombstones.Count -eq 1) 'Expected exactly one interrupted tombstone.'
        $before = Snapshot $case
        foreach ($operation in @('Rollback', 'SourceInstall', 'Watch')) {
            $next = Start-Worker $case $operation -OperationId ('b' * 32)
            Assert-Result $next 'Busy'
            Finish-Worker $next
            Assert ((Snapshot $case) -ceq $before) 'Post-rename contender changed transaction state.'
        }
        if ($interrupted) { $owner.Process.Kill(); Assert ($owner.Process.WaitForExit(10000)) 'Post-rename owner did not exit.' }
        else {
            Release-Worker $owner
            Assert-Result $owner 'Error'
            Finish-ErrorWorker $owner
        }
        Assert ([IO.File]::ReadAllText((Join-Path $case 'profile\config\sentinel.txt')) -eq 'owned profile content') 'Pre-purge interruption modified profile content.'
        Assert ([IO.File]::ReadAllText((Join-Path $case 'unrelated-profile\sentinel.txt')) -eq 'unrelated profile content') 'Post-rename interruption touched unrelated profile.'
        if (-not $interrupted) {
            # A thrown cleanup failure is not a crash: the uninstall restores
            # the prefix and leaves no tombstone, so the Settings entry stays
            # resolvable and the retry below can run.
            Assert (Test-Path -LiteralPath $prefix) 'A post-rename cleanup exception did not restore the prefix.'
            Assert (@(Get-ChildItem -LiteralPath $case -Directory -Filter 'prefix.uninstall-*').Count -eq 0) 'A post-rename cleanup exception left a tombstone.'
            $retry = Start-Worker $case 'Uninstall' '' $true
            Assert-Result $retry 'Success'
            Finish-Worker $retry
            Assert-Uninstalled $case $true
            $script:scenarios += "post-rename-interrupted-$interrupted"
            continue
        }
        # Explicit fixture recovery, not a claim of automatic production crash
        # recovery. Validate exact owned paths before moving the tree back.
        $tombstone = Resolve-CaelestiaDirectory $tombstones[0].FullName
        Assert ($tombstone -match ('^' + [regex]::Escape($prefix) + '\.uninstall-[a-f0-9]{32}$')) 'Unsafe interrupted recovery target.'
        $record = Get-Content -LiteralPath (Join-Path $tombstone 'install.json') -Raw | ConvertFrom-Json
        Assert ($record.product -eq 'caelestia-windows' -and $record.prefix -eq $prefix -and $record.installId -eq 'erm629-fixture') 'Tombstone ownership mismatch.'
        Assert-CaelestiaNoReparsePoints $tombstone
        [IO.Directory]::Move($tombstone, $prefix)
        $retry = Start-Worker $case 'Uninstall' '' $true
        Assert-Result $retry 'Success'
        Finish-Worker $retry
        Assert-Uninstalled $case $true
        $script:scenarios += "post-rename-interrupted-$interrupted"
    }
    }
    Assert ($script:scenarios.Count -ge $(if ($StaleReadOnly) { 2 } else { 38 })) 'Required transaction scenarios did not execute.'
    $passed = $true
} catch {
    $failure = Protect-CaelestiaText $_.Exception.Message
    $failureLine = $_.InvocationInfo.ScriptLineNumber
    $failureCase = $(if ($case) { Split-Path -Leaf $case } else { 'setup' })
} finally {
    foreach ($child in $script:children) {
        if (-not $child.Process.HasExited) { $child.Process.Kill(); $child.Process.WaitForExit() }
        # Retain sanitized diagnostics only, including failures. No raw logs
        # or security descriptors are part of the evidence artifact.
        foreach ($name in @('stdout.txt', 'stderr.txt')) {
            $path = Join-Path $child.Control $name
            if (Test-Path -LiteralPath $path) {
                $text = [IO.File]::ReadAllText($path)
                Write-FixtureText $path (Protect-CaelestiaText $text)
            }
        }
        $child.Process.Dispose()
    }
    $receipt = [ordered]@{
        passed = $passed; assertions = $script:assertions; scenarios = $script:scenarios; failure = $failure
        failureLine = $failureLine; failureCase = $failureCase
        sourceRevision = $revision; negativeControlRevision = $UninstallSourceRevision
        negativeControlManageRevision = $ManageSourceRevision; staleReadOnly = [bool]$StaleReadOnly
        uninstallSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1')).Hash
        manageSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Manage-Caelestia.ps1')).Hash
        backendRevision = (& git -C (Join-Path $repoRoot 'windows\deps\quickshell') rev-parse HEAD).Trim()
        glazierRevision = $captureSource.originRevision
        captureSourcePath = $captureSource.relativePath
        captureSourceRevision = $captureSource.sourceRevision
        captureCargoLockSha256 = $captureSource.cargoLockSha256
        m3shapesRevision = (& git -C (Join-Path $repoRoot 'windows\deps\m3shapes') rev-parse HEAD).Trim()
        windowsVersion = [Environment]::OSVersion.Version.ToString(); powershellVersion = $PSVersionTable.PSVersion.ToString()
        windowsBuild = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber) +
            '.' + [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR)
        architecture = $env:PROCESSOR_ARCHITECTURE
        sourceDirty = [bool](& git -C $repoRoot status --porcelain)
        fullAcceptanceComplete = $false
        limit = 'Fixture/component only; strict busy snapshots have no journal exclusion. Scheduler retries are configured but unqualified. Later queue requests recover dead/orphaned/expired journals under the prefix lock; Test-UpdateManager separately qualifies the consumer deadline. Post-rename crash recovery is explicit fixture recovery, not automatic production recovery. No live desktop/integration or release qualification.'
    }
    Write-FixtureText (Join-Path $runRoot 'receipt.json') ($receipt | ConvertTo-Json -Depth 6)
}
Write-Output ("Uninstall transaction fixture: passed={0}; assertions={1}; scenarios={2}; run={3}" -f $passed, $script:assertions, $script:scenarios.Count, (Split-Path -Leaf $runRoot))
if (-not $passed) { Write-Output "Failure case=$failureCase scriptLine=$failureLine" }
if (-not $passed) { throw $failure }
