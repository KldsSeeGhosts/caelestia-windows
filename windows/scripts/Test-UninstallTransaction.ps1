[CmdletBinding()]
param(
    [string]$OutputRoot = 'D:\Caelestia\validation-erm629',
    # Negative control: read only this revision's uninstall into the sandbox.
    [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$UninstallSourceRevision = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
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
$revision = (& git -C $repoRoot rev-parse HEAD).Trim()
$uninstallText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1'))
if ($UninstallSourceRevision) {
    $uninstallText = (& git -C $repoRoot show "${UninstallSourceRevision}:windows/scripts/Uninstall-Caelestia.ps1") -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read negative-control revision.' }
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
function New-Case([string]$Name) {
    $case = Join-Path $runRoot $Name
    $prefix = Join-Path $case 'prefix'
    $profile = Join-Path $case 'profile'
    $scripts = Join-Path $case 'scripts'
    [IO.Directory]::CreateDirectory($scripts) | Out-Null
    foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scripts
    }
    $import = ". (Join-Path `$PSScriptRoot 'Caelestia-InstallCommon.ps1')"
    $manage = [IO.File]::ReadAllText((Join-Path $scripts 'Manage-Caelestia.ps1'))
    Write-FixtureText (Join-Path $scripts 'Manage-Caelestia.ps1') (Replace-Exactly $manage $import ($import + $importBoundary))
    $uninstall = Replace-Exactly $uninstallText $import ($import + $importBoundary)
    # Exact direct Run-key boundary: never inspect or remove even a hashed
    # temporary-prefix value from the user's actual startup key.
    $uninstall = Replace-Exactly $uninstall "`$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'" `
        "`$run = Join-Path `$env:CAELESTIA_FIXTURE_CASE 'integration'"
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
        'payload/Start-DesktopShell.ps1', 'payload/Watch-DesktopShell.ps1', 'payload/Restore-Desktop.ps1',
        'payload/Install-SchemeRuntime.ps1', 'payload/Get-AccountPicture.ps1', 'payload/Banner-Suppression.ps1',
        'payload/scheme/requirements.lock.txt', 'payload/scheme/win_scheme.py', 'payload/scheme/fcntl.py',
        'payload/licenses/LICENSE', 'payload/licenses/THIRD-PARTY-NOTICES.md',
        'payload/licenses/sources.lock.json', 'payload/licenses/Glazier-LICENSE',
        'payload/licenses/Glazier-THIRD_PARTY_NOTICES.md', 'payload/licenses/M3Shapes-LICENSE',
        'payload/licenses/Quickshell-LICENSE', 'payload/licenses/Qt/LGPL-3.0.txt'
    )
    foreach ($relative in $required) { Write-FixtureText (Join-Path $bundle $relative) 'synthetic fixture data' }
    foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1')) {
        Copy-Item -LiteralPath (Join-Path $scripts $name) -Destination (Join-Path $bundle "payload\$name") -Force
    }
    foreach ($name in @('Start-Caelestia.ps1', 'Start-CaelestiaEntry.ps1')) {
        Write-FixtureText (Join-Path $bundle "payload\$name") $launcher
    }
    $releaseScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'))
    $releaseImport = ". (Join-Path `$payloadSource 'Caelestia-InstallCommon.ps1')"
    $releaseScript = Replace-Exactly $releaseScript $releaseImport ($releaseImport + $importBoundary)
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
        foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1', 'Manage-Caelestia.ps1', 'Uninstall-Caelestia.ps1')) {
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
    Write-FixtureText (Join-Path $case 'integration\fixture-run') 'owned run value'
    Write-FixtureText (Join-Path $case 'integration\shortcut.lnk') 'owned shortcut'
    return $case
}
function Start-Worker([string]$Case, [string]$Operation, [string]$Pause = '', [bool]$Purge = $false,
    [bool]$KeepAlive = $false, [bool]$ThrowAtBoundary = $false, [bool]$AliasPrefix = $false) {
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
        if ($Worker.Process.HasExited -or $clock.Elapsed.TotalSeconds -gt 30) { throw "Worker failed before $Name. Inspect local worker diagnostics." }
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
function Snapshot([string]$Case, [switch]$ExceptOperationJournal) {
    $lines = foreach ($tree in @('prefix', 'profile', 'integration', 'unrelated-profile')) {
        $path = Join-Path $Case $tree
        if (-not (Test-Path -LiteralPath $path)) { "$tree ABSENT"; continue }
        $tree
        foreach ($item in Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName) {
            $relative = $item.FullName.Substring($Case.Length + 1)
            if ($ExceptOperationJournal -and $relative -eq 'profile\state\update-operation.json') { continue }
            if ($item.PSIsContainer) { $relative + ' DIRECTORY' }
            else { $relative + ' ' + (Get-FileHash -LiteralPath $item.FullName).Hash }
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
}
function Assert-Uninstalled([string]$Case, [bool]$Purge) {
    Assert (-not (Test-Path -LiteralPath (Join-Path $Case 'prefix'))) 'Prefix not removed.'
    Assert (@(Get-ChildItem -LiteralPath $Case -Directory -Filter 'prefix.uninstall-*').Count -eq 0) 'Tombstone not cleaned.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $Case 'integration') -Force).Count -eq 0) 'Integration not removed.'
    Assert ((Test-Path -LiteralPath (Join-Path $Case 'profile')) -eq (-not $Purge)) 'Purge/profile preservation mismatch.'
    if (-not $Purge) {
        Assert ([IO.File]::ReadAllText((Join-Path $Case 'profile\config\sentinel.txt')) -eq 'owned profile content') 'Kept profile modified.'
    }
    Assert ([IO.File]::ReadAllText((Join-Path $Case 'unrelated-profile\sentinel.txt')) -eq 'unrelated profile content') 'Unrelated profile modified.'
}
$passed = $false
$failure = ''
try {
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
        foreach ($operation in @('Install', 'Rollback')) {
            $name = "held-Uninstall-vs-$operation-purge-$purge"
            $case = New-Case $name
            $owner = Start-Worker $case 'Uninstall' 'integration' $purge $true
            Wait-Marker $owner 'ready'
            $before = Snapshot $case -ExceptOperationJournal:($operation -eq 'Rollback')
            $contender = Start-Worker $case $operation
            Assert-Result $contender 'Busy'
            Finish-Worker $contender
            Assert ((Snapshot $case -ExceptOperationJournal:($operation -eq 'Rollback')) -ceq $before) 'Busy transaction mutated managed data or integration.'
            if ($operation -eq 'Rollback') {
                $journal = Get-Content -LiteralPath (Join-Path $case 'profile\state\update-operation.json') -Raw | ConvertFrom-Json
                Assert ($journal.phase -eq 'failed') 'Expected existing rollback busy journal behavior.'
            }
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
    $passed = $true
} catch {
    $failure = Protect-CaelestiaText $_.Exception.Message
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
        sourceRevision = $revision; negativeControlRevision = $UninstallSourceRevision
        uninstallSha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1')).Hash
        backendRevision = (& git -C (Join-Path $repoRoot 'windows\deps\quickshell') rev-parse HEAD).Trim()
        glazierRevision = (& git -C (Join-Path $repoRoot 'windows\deps\glazier') rev-parse HEAD).Trim()
        m3shapesRevision = (& git -C (Join-Path $repoRoot 'windows\deps\m3shapes') rev-parse HEAD).Trim()
        windowsVersion = [Environment]::OSVersion.Version.ToString(); powershellVersion = $PSVersionTable.PSVersion.ToString()
        windowsBuild = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber) +
            '.' + [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR)
        architecture = $env:PROCESSOR_ARCHITECTURE
        sourceDirty = [bool](& git -C $repoRoot status --porcelain)
        fullAcceptanceComplete = $false
        limit = 'Fixture/component only. Busy rollback writes its existing operation journal; all other managed bytes are unchanged. No live desktop/integration or actual release qualification.'
    }
    Write-FixtureText (Join-Path $runRoot 'receipt.json') ($receipt | ConvertTo-Json -Depth 6)
}
Write-Output ("Uninstall transaction fixture: passed={0}; assertions={1}; scenarios={2}; run={3}" -f $passed, $script:assertions, $script:scenarios.Count, (Split-Path -Leaf $runRoot))
if (-not $passed) { throw $failure }
