#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$QtPrefix,
    [string]$OutputRoot,
    [switch]$PureOnly,
    [switch]$MutationControls
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
if (-not $OutputRoot) {
    $OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-staged-results-' + [guid]::NewGuid().ToString('N'))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repoRoot -or $OutputRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture output must stay outside the checkout.'
}
if ($PureOnly -and $MutationControls) { throw 'MutationControls requires the QML lane; omit PureOnly.' }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$results = New-Object 'System.Collections.Generic.List[object]'
$sourceHashes = @()
$completed = $false
$qtVersion = $null
$qmlRunnerHash = $null
$dependencies = @{}
$expectedCases = @('apps-same-id-refresh', 'app-file-adapter-write-failure-recovery',
    'notification-facade-read-failure-races', 'notification-wrapper-ownership-revocation',
    'clipboard-loader-delayed-results')
$nativeOnly = @(
    @{ name = 'Windows-app-catalog-and-launch'; reason = 'Synthetic catalog only; no AppsFolder, COM, process launch or observed window outcome.' },
    @{ name = 'Windows-notification-consent-and-bus'; reason = 'Synthetic NotificationServer only; no WinRT prompt, real mutex, system toast or banner helper.' },
    @{ name = 'Filesystem-durability'; reason = 'Injected FileView completion only; no physical disk-full, ACL, QSaveFile atomicity or crash recovery qualification.' },
    @{ name = 'Windows-clipboard-worker'; reason = 'Active Caelestia.Windows wrapper with a synthetic worker; no real clipboard, OS history, privacy markers, image bytes or paste input.' },
    @{ name = 'Clipboard-picker-desktop'; reason = 'Production JS selection only; no rendered picker, keyboard/focus, mixed-DPI or physical desktop qualification.' }
)

function Invoke-OwnedProcess([string]$Executable, [string]$Arguments, [string]$Name, [string]$WorkingDirectory, [hashtable]$Environment, [int]$TimeoutMs = 20000) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Arguments
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -like 'CAELESTIA_*' -or $key -like 'QS_*' -or $key -like 'QML*' -or $key -like 'QT_*' `
                -or $key -in @('NODE_OPTIONS', 'NODE_PATH')) {
            $info.EnvironmentVariables.Remove($key)
        }
    }
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [Diagnostics.Process]::Start($info)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMs)
        if ($timedOut) { $process.Kill(); $process.WaitForExit() }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $stdout | Set-Content -LiteralPath (Join-Path $OutputRoot "$Name.stdout.log") -Encoding UTF8
        $stderr | Set-Content -LiteralPath (Join-Path $OutputRoot "$Name.stderr.log") -Encoding UTF8
        return @{ exitCode = $process.ExitCode; timedOut = $timedOut; text = "$stdout`n$stderr"; seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2) }
    } finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}

# These are the actual mapped production files. No service body is extracted
# into a fixture; imports, Loader URLs, signal handlers and singleton wiring run.
$production = @(
    'windows/services/apps/AppsService.qml',
    'windows/services/apps/NativeAppCatalog.qml',
    'windows/services/apps/AppFrequencyStore.qml',
    'windows/services/apps/FileAppFrequencyStore.qml',
    'windows/services/apps/AppStoragePath.js',
    'utils/scripts/fzf.js', 'utils/scripts/fuzzysort.js',
    'windows/services/notifications/NotificationsService.qml',
    'windows/services/notifications/NotifData.qml',
    'windows/services/notifications/NativeNotificationBackend.qml',
    'windows/services/notifications/Notifs.qml',
    'windows/services/clipboard/ClipboardHistory.qml',
    'windows/services/clipboard/NativeClipboardBackend.qml'
)
$mutations = @(
    @{ name = 'app-id-only'; source = 'windows/services/apps/AppsService.qml'; before = 'wrapper.entry === entry'; after = 'wrapper.entry.id === entry.id'; occurrences = 2; failure = 'apps.same-id-stale' },
    @{ name = 'observation-token-dropped'; source = 'windows/services/notifications/NativeNotificationBackend.qml'; before = 'server.setSystemAccessObservation(enabled === true, token ?? 0);'; after = 'server.setSystemAccessObservation(enabled === true, 0);'; occurrences = 1; failure = 'notifications.wrapper-token' },
    @{ name = 'save-failure-disconnected'; source = 'windows/services/apps/FileAppFrequencyStore.qml'; before = 'onSaveFailed: error => root.writeFinished(false, String(error))'; after = 'onSaveFailed: error => {}'; occurrences = 1; failure = 'persistence.adapter-write-failure' },
    @{ name = 'history-read-guard-removed'; source = 'windows/services/notifications/NotificationsService.qml'; before = '&& !root.historyLoadFailed;'; after = ';'; occurrences = 1; failure = 'persistence.unreadable-preserved' },
    @{ name = 'clipboard-shutdown-removed'; source = 'windows/services/clipboard/NativeClipboardBackend.qml'; before = 'Component.onDestruction: service.shutdown()'; after = 'Component.onDestruction: {}'; occurrences = 1; failure = 'clipboard.shutdown-on-unload' }
)

function Invoke-StagedQml([hashtable]$Mutation) {
    $name = if ($Mutation) { 'mutation-' + $Mutation.name } else { 'qml' }
    $run = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-staged-models-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $run 'imports\qs'
    $profile = Join-Path $stage 'profile'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        foreach ($directory in @('state', 'cache', 'config', 'runtime', 'data', 'temp')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
        }
        foreach ($source in $production) {
            $property = $map.PSObject.Properties[$source]
            if (-not $property) { throw "Required production source is not staged: $source" }
            $target = [IO.Path]::GetFullPath((Join-Path $stage $property.Value))
            if (-not $target.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source map escapes fixture stage.' }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $source) -Destination $target
            if ($Mutation -and $source -eq $Mutation.source) {
                $text = [IO.File]::ReadAllText($target)
                if ([regex]::Matches($text, [regex]::Escape($Mutation.before)).Count -ne $Mutation.occurrences) {
                    throw "Mutation anchor changed: $($Mutation.name)"
                }
                [IO.File]::WriteAllText($target, $text.Replace($Mutation.before, $Mutation.after), (New-Object Text.UTF8Encoding($false)))
            }
        }
        # Overlay only dependency providers and module descriptors, never a
        # production component under test. Catalog fake is reused unchanged.
        $fakes = Join-Path $repoRoot 'windows\tests\fakes\staged-models'
        Copy-Item -Path "$fakes\imports\*" -Destination (Join-Path $run 'imports') -Recurse -Force
        Copy-Item -LiteralPath "$repoRoot\windows\tests\fakes\apps\imports\Quickshell\DesktopEntries.qml" -Destination "$run\imports\Quickshell\DesktopEntries.qml"
        Copy-Item -LiteralPath "$fakes\services\qmldir", "$fakes\services\Hypr.qml" -Destination "$stage\services"
        New-Item -ItemType Directory -Force -Path "$stage\components\misc" | Out-Null
        Copy-Item -Path "$fakes\components\misc\*" -Destination "$stage\components\misc"
        Copy-Item -LiteralPath "$repoRoot\windows\tests\StagedServiceModelsTest.qml" -Destination "$stage\StagedServiceModelsTest.qml"
        $environment = @{
            QT_QPA_PLATFORM = 'offscreen'; QT_QUICK_BACKEND = 'software'; QT_FORCE_STDERR_LOGGING = '1'
            QT_PLUGIN_PATH = "$QtPrefix\plugins"; QT_QPA_PLATFORM_PLUGIN_PATH = "$QtPrefix\plugins\platforms"
            QML_IMPORT_PATH = "$run\imports;$QtPrefix\qml"; QML2_IMPORT_PATH = "$run\imports;$QtPrefix\qml"
            QML_DISK_CACHE_PATH = "$profile\cache"; HOME = $profile; USERPROFILE = $profile
            APPDATA = "$profile\config"; LOCALAPPDATA = "$profile\data"; TEMP = "$profile\temp"; TMP = "$profile\temp"
        }
        $actual = Invoke-OwnedProcess "$QtPrefix\bin\qml.exe" ('"' + "$stage\StagedServiceModelsTest.qml" + '"') $name $stage $environment
        $diagnostics = @([regex]::Matches($actual.text, '(?im)^.*(?:ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|Cannot read property|is not a type|is not installed|is not a function|is not defined|failed to load component).*$') | ForEach-Object Value)
        $payload = $null
        $match = [regex]::Match($actual.text, 'CAELESTIA_STAGED_MODELS_PASS (\{[^\r\n]+\})')
        if ($match.Success) { $payload = $match.Groups[1].Value | ConvertFrom-Json }
        if ($Mutation) {
            $passed = -not $actual.timedOut -and $actual.exitCode -ne 0 -and $diagnostics.Count -eq 0 `
                -and $actual.text.Contains("CAELESTIA_STAGED_MODELS_FAIL Error: $($Mutation.failure)") -and -not $match.Success
        } else {
            $passed = -not $actual.timedOut -and $actual.exitCode -eq 0 -and $diagnostics.Count -eq 0 -and $null -ne $payload `
                -and $payload.assertions -eq 36 -and $payload.cases.Count -eq $expectedCases.Count `
                -and @(Compare-Object $expectedCases $payload.cases).Count -eq 0 `
                -and $actual.text -notmatch 'CAELESTIA_STAGED_MODELS_FAIL'
        }
        $results.Add([ordered]@{ name = $name; passed = $passed; exitCode = $actual.exitCode; timedOut = $actual.timedOut
            seconds = $actual.seconds; fixture = $payload; diagnostics = $diagnostics
            expectedFailure = if ($Mutation) { $Mutation.failure } else { $null } })
        Write-Output ("{0} {1}" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $name)
        if (-not $passed) { Write-Output $actual.text }
    } finally {
        $resolved = [IO.Path]::GetFullPath($run)
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        try {
            if ((Split-Path -Parent $resolved) -ne $tempParent -or (Split-Path -Leaf $resolved) -notlike 'caelestia-staged-models-*') {
                throw 'Refusing cleanup outside the owned fixture directory.'
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        } catch {
            # Keep the original fixture failure while making cleanup failure fatal
            # to the aggregate result when there was no earlier exception.
            $results.Add(@{ name = 'cleanup'; passed = $false; reason = 'owned-fixture-cleanup-failed' })
            Write-Warning 'Owned fixture cleanup failed; retained output requires inspection.'
        }
    }
}

try {
    foreach ($dependency in @(@{name = 'backend'; directory = 'quickshell'}, @{name = 'm3shapes'; directory = 'm3shapes'})) {
        if ($PureOnly) { continue } # JavaScript does not load native dependencies.
        $directory = Join-Path $repoRoot ('windows\deps\' + $dependency.directory)
        $topLevel = & git -C $directory rev-parse --show-toplevel
        if ($LASTEXITCODE -ne 0 -or -not $topLevel -or [IO.Path]::GetFullPath($topLevel.Trim()) -ne [IO.Path]::GetFullPath($directory)) {
            throw "Dependency is not initialized as its own checkout: $($dependency.directory)"
        }
        $revision = & git -C $directory rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or -not $revision) { throw "Cannot identify dependency: $($dependency.directory)" }
        $dependencies[$dependency.name] = $revision.Trim()
    }
    if (-not $PureOnly) {
        . (Join-Path $repoRoot 'windows\capture\Source.ps1')
        $captureSource = Get-CaelestiaCaptureSource $repoRoot
        $dependencies['capture'] = [ordered]@{
            sourceRevision = $captureSource.sourceRevision
            cargoLockSha256 = $captureSource.cargoLockSha256
            originRevision = $captureSource.originRevision
        }
    }
    $node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $js = Invoke-OwnedProcess $node ('--test --test-reporter=tap "' + "$repoRoot\windows\tests\StagedClipboardModels.test.js" + '"') 'javascript' $repoRoot @{}
    $count = [regex]::Match($js.text, '(?m)^# tests ([0-9]+)\s*$')
    $passes = [regex]::Match($js.text, '(?m)^# pass ([0-9]+)\s*$')
    $skips = [regex]::Match($js.text, '(?m)^# skipped ([0-9]+)\s*$')
    $passed = -not $js.timedOut -and $js.exitCode -eq 0 -and $count.Success -and [int]$count.Groups[1].Value -eq 5 `
        -and $passes.Success -and $passes.Groups[1].Value -eq $count.Groups[1].Value -and $skips.Success -and [int]$skips.Groups[1].Value -eq 0
    $results.Add([ordered]@{ name = 'javascript'; passed = $passed; exitCode = $js.exitCode; timedOut = $js.timedOut
        tests = if ($count.Success) { [int]$count.Groups[1].Value } else { 0 }; seconds = $js.seconds; skipped = 0 })
    Write-Output ("{0} javascript ({1} tests)" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $results[0].tests)
    if (-not $passed) { Write-Output $js.text }
    if (-not $PureOnly) {
        if (-not $QtPrefix) { throw 'QtPrefix is required for QML fixtures; use PureOnly for the portable JavaScript lane.' }
        $QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
        foreach ($file in @('bin\qml.exe', 'bin\qtpaths.exe', 'plugins\platforms\qoffscreen.dll')) {
            if (-not (Test-Path -LiteralPath (Join-Path $QtPrefix $file) -PathType Leaf)) { throw "Missing Qt prerequisite: $file" }
        }
        # qtpaths is a console tool. Never probe qml.exe with help/version:
        # that GUI-linked executable can open a physical usage dialog.
        $qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'qtpaths could not identify Qt.' }
        $qmlRunnerHash = (Get-FileHash -LiteralPath "$QtPrefix\bin\qml.exe").Hash
        $map = Get-Content -LiteralPath "$repoRoot\windows\shell\sources.json" -Raw | ConvertFrom-Json
        $sourceHashes = @($production | ForEach-Object { @{ source = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot $_)).Hash } })
        Invoke-StagedQml $null
        if ($MutationControls -and $results[$results.Count - 1].passed) {
            foreach ($mutation in $mutations) { Invoke-StagedQml $mutation }
        }
    }
    $completed = $true
} finally {
    $summary = [ordered]@{
        schemaVersion = 1; evidenceClass = 'fixture/component'
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        sourceDirty = [bool](& git -C $repoRoot status --porcelain)
        dependencies = $dependencies
        qtVersion = $qtVersion; qmlRunnerSha256 = $qmlRunnerHash
        javascriptSourceSha256 = (Get-FileHash -LiteralPath "$repoRoot\windows\services\clipboard\ClipboardHistory.js").Hash
        fileUrlsSourceSha256 = (Get-FileHash -LiteralPath "$repoRoot\windows\shell\adapters\utils\FileUrls.js").Hash
        mode = if ($PureOnly) { 'pure-only' } else { 'pure-and-qml' }
        mutationControls = @{
            requested = [bool]$MutationControls
            completed = @($results | Where-Object { $_.name -like 'mutation-*' }).Count
            notRunReason = if (-not $MutationControls) { 'Not requested; use -MutationControls for QML behavior mutations.' }
                elseif (@($results | Where-Object { $_.name -like 'mutation-*' }).Count -ne $mutations.Count) { 'Baseline or prerequisite failure; controls require a passing baseline.' }
                else { $null }
        }
        passed = $completed -and $results.Count -gt 0 -and @($results | Where-Object { -not $_.passed }).Count -eq 0
        results = @($results.ToArray()); productionSources = $sourceHashes
        skipped = @($nativeOnly) + @($(if ($PureOnly) { @{name = 'qml'; reason = 'Explicit PureOnly request; Qt fixtures not run.'} }))
        externalDependencies = @('URL regression fixtures owned separately; not run here', 'Failed-close fixtures owned separately; not run here')
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json') -Encoding UTF8
}
if (-not $summary.passed) { throw "Staged service model fixtures failed. See $OutputRoot." }
