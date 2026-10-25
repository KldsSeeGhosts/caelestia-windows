[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$exe = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Qt QML runner: $exe" }
$runName = 'notifications-fixture-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = Join-Path $BuildRoot "notification-tests\$runName"
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $stage, $logRoot | Out-Null
# Copy only the pure state/history object and its fixture. No native backend,
# singleton facade or Quickshell module is present in this stage; qml.exe does
# not load Quickshell, so NotificationServer cannot be constructed here.
$sources = foreach ($name in @('NotificationsService.qml', 'NotifData.qml', 'NotificationsServiceTest.qml')) {
    $source = Join-Path $repoRoot "windows\services\notifications\$name"
    $target = Join-Path $stage $name
    Copy-Item -LiteralPath $source -Destination $target
    [ordered]@{
        source = "windows/services/notifications/$name"
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
$serviceSource = Join-Path $repoRoot 'windows\services\notifications\NotificationsService.qml'
$recordSource = Join-Path $repoRoot 'windows\services\notifications\NotifData.qml'
$facadeSource = Join-Path $repoRoot 'windows\services\notifications\Notifs.qml'
$backendSource = Join-Path $repoRoot 'windows\services\notifications\NativeNotificationBackend.qml'
$serviceText = Get-Content -LiteralPath $serviceSource -Raw
$recordText = Get-Content -LiteralPath $recordSource -Raw
$facadeText = Get-Content -LiteralPath $facadeSource -Raw
$backendText = Get-Content -LiteralPath $backendSource -Raw
$nativeImports = @(Select-String -LiteralPath $serviceSource, $recordSource -Pattern '^\s*import\s+Quickshell')
$servicePathFallbacks = @(Select-String -LiteralPath $serviceSource -CaseSensitive -Pattern 'Quickshell\.env\(\s*["''](?:HOME|XDG_)|Paths\.(state|cache|notifimagecache)|Quickshell\.(stateDir|cacheDir)')
$recordPathFallbacks = @(Select-String -LiteralPath $recordSource -CaseSensitive -Pattern 'Quickshell\.env\(\s*["''](?:HOME|XDG_)|Paths\.(state|cache|notifimagecache)|Hypr|CUtils|saveItem')
$facadePathFallbacks = @(Select-String -LiteralPath $facadeSource -CaseSensitive -Pattern 'Quickshell\.env\(\s*["''](?:HOME|XDG_)|Paths\.(state|cache|notifimagecache)')
$serviceImageCache = @(Select-String -LiteralPath $serviceSource -CaseSensitive -Pattern 'notifimagecache')
# The wrapper must set mirroring false at construction and must never request
# notification access or re-enable mirroring. The facade must not call the
# request invokable either.
$mirrorSetting = @(Select-String -LiteralPath $backendSource -Pattern 'mirrorSystemNotifications:\s*false')
$mirrorEnabled = @(Select-String -LiteralPath $backendSource -Pattern 'mirrorSystemNotifications:\s*true')
$accessRequest = @(Select-String -LiteralPath $backendSource, $facadeSource -Pattern 'requestSystemNotificationAccess|requestAccess\(|ToastMirror')
$hashMismatch = @($sources | Where-Object { $_.sourceSha256 -ne $_.stagedSha256 })

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '"' + (Join-Path $stage 'NotificationsServiceTest.qml') + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $stage 'cache'
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(20000)
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdoutPath = Join-Path $logRoot "$runName.stdout.log"
$stderrPath = Join-Path $logRoot "$runName.stderr.log"
$stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
$stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
$combined = "$stdout`n$stderr"
$match = [regex]::Match($combined, 'CAELESTIA_NOTIFICATIONS_FIXTURE_PASS (\{[^\r\n]+\})')
$fixture = $(if ($match.Success) { $match.Groups[1].Value | ConvertFrom-Json } else { $null })
$diagnostics = @([regex]::Matches(
    $combined,
    '(?im)^.*(?:CAELESTIA_NOTIFICATIONS_FIXTURE_FAIL|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|is not a type|Cannot read property|is not defined|is not a function|Cannot call method).*$'
))
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and $match.Success -and
    $null -ne $fixture -and [int]$fixture.assertions -ge 130 -and
    $hashMismatch.Count -eq 0 -and $nativeImports.Count -eq 0 -and
    $servicePathFallbacks.Count -eq 0 -and $recordPathFallbacks.Count -eq 0 -and
    $facadePathFallbacks.Count -eq 0 -and
    $serviceImageCache.Count -eq 0 -and $mirrorSetting.Count -eq 1 -and
    $mirrorEnabled.Count -eq 0 -and $accessRequest.Count -eq 0 -and
    $serviceText -notmatch 'NotificationServer' -and
    $recordText -notmatch 'NotificationServer' -and
    $diagnostics.Count -eq 0
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
    fixture = $fixture
    nativeImports = @($nativeImports)
    servicePathFallbacks = @($servicePathFallbacks)
    recordPathFallbacks = @($recordPathFallbacks)
    facadePathFallbacks = @($facadePathFallbacks)
    serviceImageCacheReferences = @($serviceImageCache)
    mirrorSetting = @($mirrorSetting)
    mirrorEnabled = @($mirrorEnabled)
    accessRequests = @($accessRequest)
    hashMismatch = @($hashMismatch)
    diagnostics = @($diagnostics | ForEach-Object { $_.Value })
    staticChecks = [ordered]@{
        serviceImportsNoQuickshell = $nativeImports.Count -eq 0
        serviceImportsNoPaths = $servicePathFallbacks.Count -eq 0
        recordIsPure = $recordPathFallbacks.Count -eq 0
        recordNeverConstructsServer = $recordText -notmatch 'NotificationServer'
        facadeImportsNoPaths = $facadePathFallbacks.Count -eq 0
        serviceUsesNoUpstreamImageCache = $serviceImageCache.Count -eq 0
        serviceNeverConstructsServer = $serviceText -notmatch 'NotificationServer'
        wrapperMirroringFalseAtConstruction = $mirrorSetting.Count -eq 1
        wrapperNeverEnablesMirroring = $mirrorEnabled.Count -eq 0
        noNotificationAccessRequest = $accessRequest.Count -eq 0
    }
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    runnerSha256 = (Get-FileHash -LiteralPath $exe).Hash
    command = $exe; arguments = $info.Arguments; sources = @($sources)
    stage = $stage; stdout = $stdoutPath; stderr = $stderrPath
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logRoot "$runName.json") -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $passed) { throw "Notification fixture failed. See $stdoutPath and $stderrPath." }
