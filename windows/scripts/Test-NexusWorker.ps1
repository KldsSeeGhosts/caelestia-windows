#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\Caelestia-Update.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not $OutputRoot) { $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-nexus-worker-' + [guid]::NewGuid().ToString('N')) }
$OutputRoot = Resolve-CaelestiaDirectory $OutputRoot
if (Test-Path -LiteralPath $OutputRoot) { throw 'Worker fixtures require fresh output.' }
[IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
$runRoot = $OutputRoot
$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$revision = 'a' * 40
$boundary = Join-Path $PSScriptRoot 'UninstallTransaction-FixtureBoundary.ps1'
$importBoundary = "`r`n. '" + $boundary.Replace("'", "''") + "'"
$uninstallText = [IO.File]::ReadAllText("$PSScriptRoot\Uninstall-Caelestia.ps1")
$manageText = [IO.File]::ReadAllText("$PSScriptRoot\Manage-Caelestia.ps1")
# Reuse the established complete inert bundle builder, not an alternate
# installer. No top-level code from either test is evaluated.
foreach ($definition in @(
    @{ file = 'Test-UninstallTransaction.ps1'; names = @('Replace-Exactly', 'Write-FixtureText', 'New-Case') },
    @{ file = 'Test-UpdateTrust.ps1'; names = @('New-Key', 'JsonBytes', 'Strict', 'Sign') }
)) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $definition.file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Fixture dependency failed to parse.' }
    foreach ($name in $definition.names) {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $function) { throw 'Fixture dependency missing.' }
        $definitionText = $function.Extent.Text.Replace('(Join-Path $PSScriptRoot ', ("(Join-Path '" + $PSScriptRoot.Replace("'", "''") + "' "))
        . ([scriptblock]::Create($definitionText))
    }
}
$rootKey = New-Key; $devKey = New-Key
$count = 0
$children = @()
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message }; $script:count++ }
function Prepare-Case([string]$Name, [string]$Mutation = '') {
    $case = New-Case $Name
    $prefix = Join-Path $case 'prefix'
    $profile = Join-Path $case 'profile'
    $newId = '0.2.0-dev.1.2.1'
    $current = Read-CaelestiaInstall (Join-Path $prefix 'versions\v2')
    $current | Add-Member -NotePropertyName releaseId -NotePropertyValue '0.2.0-dev.1.1.1' -Force
    $current | Add-Member -NotePropertyName appVersion -NotePropertyValue '0.2.0' -Force
    Write-CaelestiaJsonAtomic (Join-Path $prefix 'versions\v2\install.json') $current
    [IO.Directory]::CreateDirectory((Join-Path $profile 'state\updates')) | Out-Null
    Write-CaelestiaJsonAtomic (Join-Path $profile 'state\updates\settings.json') @{ schema = 1; channel = 'development' }
    foreach ($name in @('shell.json', 'windows.json', 'keybinds.json')) {
        Write-FixtureText (Join-Path $profile "config\$name") '{"fixtureUnknownSetting":{"retained":true},"schema":1}'
    }
    $future = [DateTime]::UtcNow.AddDays(30).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $trust = @{
        schema = 'caelestia-update-trust'; version = 1; rootVersion = 1; status = 'configured'
        repository = 'KldsSeeGhosts/caelestia-windows'
        metadataBase = 'https://raw.githubusercontent.com/KldsSeeGhosts/caelestia-windows/nexus-channels/v1/'
        assetPrefix = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/'
        redirectHosts = @('objects.githubusercontent.com', 'release-assets.githubusercontent.com')
        rootKeys = @($rootKey.Public); rootThreshold = 1; requireAuthenticode = $false
    }
    # Inject only into disposable entrypoints. No production env/CLI test hook.
    $import = ". (Join-Path `$PSScriptRoot 'Caelestia-Update.ps1')"
    $manage = Replace-Exactly ([IO.File]::ReadAllText("$case\scripts\Manage-Caelestia.ps1")) $import `
        ($import + "`r`n. '" + (Join-Path $PSScriptRoot 'NexusWorker-FixtureBoundary.ps1').Replace("'", "''") + "'")
    foreach ($where in @("$case\scripts", $prefix)) {
        Write-FixtureText (Join-Path $where 'Manage-Caelestia.ps1') $manage
        Write-CaelestiaJsonAtomic (Join-Path $where 'update-trust.json') $trust
    }
    $bundle = Join-Path $case 'bundle'
    Write-FixtureText "$bundle\payload\Manage-Caelestia.ps1" $manage
    $manifest = Get-Content "$bundle\release.json" -Raw | ConvertFrom-Json
    $manifest.releaseId = $newId
    $manifest | Add-Member -NotePropertyName profileSchema -NotePropertyValue 1 -Force
    # Reapply recording integration/readiness boundary after the bootstrap's
    # verified supplied common helper import.
    $bootstrap = [IO.File]::ReadAllText("$bundle\Install-CaelestiaRelease.ps1")
    $releaseImport = ". (Join-Path `$payloadSource 'Caelestia-InstallCommon.ps1')"
    $bootstrap = Replace-Exactly $bootstrap $releaseImport `
        ($releaseImport + "`r`n. '" + (Join-Path $PSScriptRoot 'NexusWorker-FixtureBoundary.ps1').Replace("'", "''") + "'")
    Write-FixtureText "$bundle\Install-CaelestiaRelease.ps1" $bootstrap
    # New bootstrap compatibility fields are intentionally additive to this
    # legacy-format synthetic bundle. Real capture/binaries never execute.
    $manifest.files = @(Get-ChildItem -LiteralPath $bundle -File -Recurse | Where-Object Name -ne 'release.json' | ForEach-Object {
        @{ path = $_.FullName.Substring($bundle.Length + 1).Replace('\', '/'); size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
    })
    Write-CaelestiaJsonAtomic "$bundle\release.json" $manifest
    $manifestHash = (Get-FileHash "$bundle\release.json").Hash.ToLowerInvariant()
    $zipRoot = "caelestia-windows-$newId-windows-x64"
    [IO.Directory]::Move($bundle, (Join-Path $case $zipRoot))
    New-CaelestiaUpdateArchive (Join-Path $case $zipRoot) "$case\download.zip"
    $archive = [IO.Compression.ZipFile]::OpenRead("$case\download.zip")
    try { $entries = $archive.Entries.Count; $unpacked = ($archive.Entries | Measure-Object Length -Sum).Sum } finally { $archive.Dispose() }
    $keys = @{ type = 'caelestia-update-keys'; schema = 1; repository = $trust.repository; version = 1; expires = $future; threshold = 1
        keys = @(@{ public = $devKey.Public; channels = @('development'); notAfter = $future }) }
    $channel = @{ type = 'caelestia-update-channel'; schema = 1; repository = $trust.repository; channel = 'development'; sequence = 1
        issuedAt = [DateTime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        expires = [DateTime]::UtcNow.AddDays(14).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); keysVersion = 1
        release = @{ displayVersion = $newId; buildVersion = $newId; releaseId = $newId; tag = "v$newId"
            sourceRevision = $revision; backendRevision = $manifest.backendRevision; manifestSha256 = $manifestHash
            profileSchema = 1; minimumUpdaterSchema = 1
            notesUrl = "https://github.com/$($trust.repository)/releases/tag/v$newId"
            bundle = @{ name = "$zipRoot.zip"; root = $zipRoot; url = $trust.assetPrefix + "v$newId/$zipRoot.zip"
                sha256 = (Get-FileHash "$case\download.zip").Hash.ToLowerInvariant()
                size = (Get-Item "$case\download.zip").Length; entries = $entries; unpackedSize = [long]$unpacked }
            provenance = @{ runId = '2'; runAttempt = '1'; pairResultSha256 = 'e' * 64; candidateReceiptSha256 = 'f' * 64 } } }
    if ($Mutation -eq 'manifest') { $channel.release.manifestSha256 = '0' * 64 }
    if ($Mutation -eq 'target') { $channel.release.buildVersion = '0.2.0-dev.1.3.1'; $channel.release.releaseId = $channel.release.buildVersion
        $channel.release.displayVersion = $channel.release.buildVersion; $channel.release.tag = 'v' + $channel.release.buildVersion
        $r = $channel.release.buildVersion; $z = "caelestia-windows-$r-windows-x64"
        $channel.release.bundle.name = "$z.zip"; $channel.release.bundle.root = $z
        $channel.release.bundle.url = $trust.assetPrefix + "v$r/$z.zip"
        $channel.release.notesUrl = "https://github.com/$($trust.repository)/releases/tag/v$r" }
    [IO.Directory]::CreateDirectory("$case\metadata") | Out-Null
    [IO.File]::WriteAllBytes("$case\metadata\keys.dsse.json", (Sign $keys 'keys' $rootKey))
    [IO.File]::WriteAllBytes("$case\metadata\development.dsse.json", (Sign $channel 'channel' $devKey))
    return $case
}
function Start-Worker([string]$Case, [string]$Arguments, [string]$Pause = '') {
    $control = Join-Path $Case ('control-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($control) | Out-Null
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Get-WindowsPowerShellPath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($entry in @{
        CAELESTIA_FIXTURE_CASE = $Case; CAELESTIA_FIXTURE_PREFIX = "$Case\prefix"; CAELESTIA_FIXTURE_PROFILE = "$Case\profile"
        CAELESTIA_FIXTURE_CONTROL = $control; CAELESTIA_FIXTURE_PAUSE = $Pause; CAELESTIA_FIXTURE_OPERATION = 'Nexus'
        LOCALAPPDATA = "$Case\cache"
    }.GetEnumerator()) { $info.EnvironmentVariables[$entry.Key] = $entry.Value }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $null = $process.Start()
    $child = @{ process = $process; stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync(); control = $control }
    $script:children += $child
    return $child
}
function Finish($Child, [bool]$Success = $true) {
    if (-not $Child.process.WaitForExit(20000)) { throw 'Fixture worker timed out.' }
    $out = $Child.stdout.GetAwaiter().GetResult(); $err = $Child.stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $Child.control 'stdout.private.log'), $out)
    [IO.File]::WriteAllText((Join-Path $Child.control 'stderr.private.log'), $err)
    Assert (($Child.process.ExitCode -eq 0) -eq $Success) "Unexpected worker exit: $err"
    return $out
}
function Args([string]$Case, [string]$Extra) {
    return '-NoProfile -NonInteractive -File "' + "$Case\prefix\Manage-Caelestia.ps1" + '" -Prefix "' + "$Case\prefix" + '" ' + $Extra
}
function Queue([string]$Case) {
    $out = Finish (Start-Worker $Case (Args $Case '-Command Update -ExpectedCurrent v2 -ExpectedBuild 0.2.0-dev.1.2.1 -Channel development'))
    $id = ($out | ConvertFrom-Json).operationId
    Assert ($id -match '^[a-f0-9]{32}$') 'Queue did not acknowledge an operation.'
    return $id
}
function TaskArgs([string]$Case, [string]$Id) {
    return (Get-Content "$Case\tasks\Caelestia-Maintenance-$Id.json" -Raw | ConvertFrom-Json).Actions[0].Arguments
}
try {
    $case = Prepare-Case 'happy'
    $profileHash = (Get-FileHash "$case\profile\config\sentinel.txt").Hash
    $configHashes = @{}
    foreach ($file in Get-ChildItem "$case\profile\config" -File) { $configHashes[$file.Name] = (Get-FileHash $file.FullName).Hash }
    $checked = Finish (Start-Worker $case (Args $case '-Command CheckUpdate'))
    Assert (($checked | ConvertFrom-Json).state -ceq 'available') 'Authenticated check before queue did not offer target.'
    $id = Queue $case
    $null = Finish (Start-Worker $case (TaskArgs $case $id))
    $record = Read-CaelestiaInstall "$case\prefix"
    Assert ($record.current -ne 'v2' -and $record.previous -eq 'v2') 'Update did not retain previous working payload.'
    $selected = Read-CaelestiaInstall (Get-CaelestiaVersionPrefix "$case\prefix" $record.current)
    Assert ($selected.releaseId -ceq '0.2.0-dev.1.2.1' -and $selected.installedChannel -ceq 'development') 'Installed authenticated identity/channel mismatch.'
    Assert ((Get-FileHash "$case\profile\config\sentinel.txt").Hash -ceq $profileHash) 'Worker changed existing settings.'
    foreach ($name in $configHashes.Keys) {
        Assert ((Get-FileHash "$case\profile\config\$name").Hash -ceq $configHashes[$name]) 'Existing JSON settings/unknown fields changed.'
    }
    Assert ((Get-Content "$case\profile\state\update-operation.json" -Raw | ConvertFrom-Json).phase -ceq 'complete') 'Worker did not complete journal.'
    $history = @(Get-ChildItem "$case\control-*\progress.jsonl" | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
    $downloads = @($history | Where-Object { $_.step -eq 'downloading' -and $_.progress.total -gt 0 })
    Assert ($downloads.Count -ge 2) 'Worker did not journal measured download progress.'
    Assert ($downloads[0].progress.completed -eq 0 -and $downloads[0].progress.unit -eq 'bytes') 'Worker download initial totals missing.'
    Assert ($downloads[-1].progress.completed -eq (Get-Item "$case\download.zip").Length -and
        $downloads[-1].progress.total -eq $downloads[-1].progress.completed) 'Worker download did not report signed byte total.'
    $extraction = @($history | Where-Object { $_.step -eq 'verifying' -and $_.progress.unit -eq 'entries' })
    Assert ($extraction.Count -ge 2 -and $extraction[0].progress.completed -eq 0 -and
        $extraction[-1].progress.completed -eq $extraction[-1].progress.total) 'Worker extraction entry progress missing.'
    Assert (@($history | Where-Object { $_.step -eq 'installing' -and $_.progress.total -eq 0 }).Count -gt 0) 'Installer fabricated a measured fraction.'
    Assert (@(Get-ChildItem "$case\cache" -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) 'Worker left successful download bytes.'
    $highwaterHash = (Get-FileHash "$case\trust\highwater.json").Hash
    $null = Finish (Start-Worker $case (Args $case ('-Command Rollback -Wait -ExpectedCurrent ' + $record.current)))
    Assert ((Read-CaelestiaInstall "$case\prefix").current -eq 'v2') 'Rollback after authenticated update failed.'
    Assert ((Get-FileHash "$case\trust\highwater.json").Hash -ceq $highwaterHash) 'Rollback erased trust highwater.'
    $id = Queue $case
    $null = Finish (Start-Worker $case (TaskArgs $case $id))
    Assert ((Read-CaelestiaInstall "$case\prefix").current -ne 'v2') 'Update after rollback failed.'
    $case = Prepare-Case 'metadata-toctou'
    $checked = Finish (Start-Worker $case (Args $case '-Command CheckUpdate'))
    Assert (($checked | ConvertFrom-Json).available.buildVersion -ceq '0.2.0-dev.1.2.1') 'Initial TOCTOU check failed.'
    $id = Queue $case
    $envelope = Read-CaelestiaStrictJsonFile "$case\metadata\development.dsse.json"
    $changed = ConvertFrom-CaelestiaStrictJson ([Caelestia.Update.Security]::Base64($envelope.payload))
    $changed['sequence'] = 2L
    $newBuild = '0.2.0-dev.1.3.1'
    foreach ($field in @('displayVersion', 'buildVersion', 'releaseId')) { $changed.release[$field] = $newBuild }
    $changed.release['tag'] = "v$newBuild"
    $newRoot = "caelestia-windows-$newBuild-windows-x64"
    $changed.release.bundle['root'] = $newRoot; $changed.release.bundle['name'] = "$newRoot.zip"
    $changed.release.bundle['url'] = "https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v$newBuild/$newRoot.zip"
    $changed.release['notesUrl'] = "https://github.com/KldsSeeGhosts/caelestia-windows/releases/tag/v$newBuild"
    [IO.File]::WriteAllBytes("$case\metadata\development.dsse.json", (Sign $changed 'channel' $devKey))
    $null = Finish (Start-Worker $case (TaskArgs $case $id)) $false
    Assert ((Read-CaelestiaInstall "$case\prefix").current -ceq 'v2') 'Changed authenticated target installed after request.'
    Assert (-not (Get-ChildItem "$case\control-*\boundaries.txt" -ErrorAction SilentlyContinue | Select-String '^download$')) 'TOCTOU target mismatch downloaded a bundle.'
    foreach ($mutation in @('manifest', 'target', 'stale')) {
        $case = Prepare-Case $mutation $mutation
        $id = Queue $case
        if ($mutation -eq 'stale') {
            $record = Read-CaelestiaInstall "$case\prefix"; $record.current = 'v1'; $record.previous = 'v2'
            Write-CaelestiaJsonAtomic "$case\prefix\install.json" $record
        }
        $before = (Get-FileHash "$case\prefix\install.json").Hash
        $null = Finish (Start-Worker $case (TaskArgs $case $id)) $false
        Assert ((Get-FileHash "$case\prefix\install.json").Hash -ceq $before) "Refused $mutation changed selector."
        Assert ((Get-Content "$case\profile\state\update-operation.json" -Raw | ConvertFrom-Json).phase -ceq 'failed') "Refused $mutation did not settle."
        Assert (-not (Get-ChildItem "$case\control-*\boundaries.txt" -ErrorAction SilentlyContinue | Select-String 'complete-integration')) 'Unverified bundle reached activation.'
    }
    $case = Prepare-Case 'concurrency'
    $id = Queue $case
    $null = Finish (Start-Worker $case (Args $case '-Command Rollback -ExpectedCurrent v2')) $false
    $null = Finish (Start-Worker $case (Args $case '-Command Update -ExpectedCurrent v2 -ExpectedBuild 0.2.0-dev.1.2.1 -Channel development')) $false
    $worker = Start-Worker $case (TaskArgs $case $id) 'download'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path "$($worker.control)\ready")) {
        if ($clock.Elapsed.TotalSeconds -gt 10) { throw 'Download boundary not reached.' }
        Start-Sleep -Milliseconds 20
    }
    $journalHash = (Get-FileHash "$case\profile\state\update-operation.json").Hash
    $null = Finish (Start-Worker $case (Args $case '-Command Rollback -Wait')) $false
    $null = Finish (Start-Worker $case (Args $case ("-Command Watch -OperationId $id"))) $false
    Assert ((Get-FileHash "$case\profile\state\update-operation.json").Hash -ceq $journalHash) 'Busy watchdog/rollback changed live worker journal.'
    [IO.File]::WriteAllText("$($worker.control)\release", '')
    $null = Finish $worker
    # The inverse queue exclusion: a pending rollback also owns the slot.
    $case = Prepare-Case 'rollback-queued'
    $null = Finish (Start-Worker $case (Args $case '-Command Rollback -ExpectedCurrent v2'))
    $before = (Get-FileHash "$case\profile\state\update-operation.json").Hash
    $null = Finish (Start-Worker $case (Args $case '-Command Update -ExpectedCurrent v2 -ExpectedBuild 0.2.0-dev.1.2.1 -Channel development')) $false
    Assert ((Get-FileHash "$case\profile\state\update-operation.json").Hash -ceq $before) 'Update replaced a live rollback request.'
    # A late selector edit must still refuse at activation, even if another
    # caller violated the mutex contract. The fixture edits owned data only.
    $case = Prepare-Case 'activation-fence'
    $id = Queue $case
    $worker = Start-Worker $case (TaskArgs $case $id) 'download'
    $clock.Restart()
    while (-not (Test-Path "$($worker.control)\ready")) {
        if ($clock.Elapsed.TotalSeconds -gt 10) { throw 'Activation fence boundary not reached.' }
        Start-Sleep -Milliseconds 20
    }
    $record = Read-CaelestiaInstall "$case\prefix"; $record.current = 'v1'; $record.previous = 'v2'
    Write-CaelestiaJsonAtomic "$case\prefix\install.json" $record
    [IO.File]::WriteAllText("$($worker.control)\release", '')
    $null = Finish $worker $false
    Assert ((Read-CaelestiaInstall "$case\prefix").current -eq 'v1') 'Late selector edit was overwritten at activation.'
    # Simulate scheduler hard termination of only our paused worker. A later
    # watchdog settles its journal and the unchanged selector stays usable.
    $case = Prepare-Case 'interrupted-worker'
    $id = Queue $case
    $worker = Start-Worker $case (TaskArgs $case $id) 'download'
    $clock.Restart()
    while (-not (Test-Path "$($worker.control)\ready")) {
        if ($clock.Elapsed.TotalSeconds -gt 10) { throw 'Interruption boundary not reached.' }
        Start-Sleep -Milliseconds 20
    }
    $worker.process.Kill(); $worker.process.WaitForExit()
    $null = Finish (Start-Worker $case (Args $case ("-Command Watch -OperationId $id")))
    Assert ((Get-Content "$case\profile\state\update-operation.json" -Raw | ConvertFrom-Json).phase -ceq 'failed') 'Watchdog did not settle interrupted update.'
    Assert ((Read-CaelestiaInstall "$case\prefix").current -eq 'v2') 'Interrupted download changed selector.'
    # A watchdog that wins before a queued worker fences its later start.
    $case = Prepare-Case 'watchdog'
    $id = Queue $case; $arguments = TaskArgs $case $id
    $null = Finish (Start-Worker $case (Args $case ("-Command Watch -OperationId $id")))
    $null = Finish (Start-Worker $case $arguments) $false
    Assert ((Read-CaelestiaInstall "$case\prefix").current -eq 'v2') 'Fenced worker activated after watchdog.'
    # Expired queued update is fenced by a replacement rollback request.
    $case = Prepare-Case 'expired'
    $id = Queue $case; $arguments = TaskArgs $case $id
    $journal = Get-Content "$case\profile\state\update-operation.json" -Raw | ConvertFrom-Json
    $journal.queuedDeadlineUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    Write-CaelestiaJsonAtomic "$case\profile\state\update-operation.json" $journal
    $null = Finish (Start-Worker $case (Args $case '-Command Rollback -ExpectedCurrent v2'))
    $null = Finish (Start-Worker $case $arguments) $false
    Assert ((Read-CaelestiaInstall "$case\prefix").current -eq 'v2') 'Expired worker bypassed replacement fence.'
    if ($count -lt 81) { throw 'Authenticated worker assertion inventory unexpectedly reduced.' }
    Write-Output "PASS authenticated worker: $count assertions; actual queued args, crypto, installer and rollback; recording external boundaries only."
} finally {
    foreach ($child in $children) {
        if (-not $child.process.HasExited) { $child.process.Kill(); $child.process.WaitForExit() }
        $child.process.Dispose()
    }
    foreach ($key in @($rootKey, $devKey)) { [Array]::Clear($key.Private, 0, $key.Private.Length) }
}
