[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$serviceSource = Join-Path $repoRoot 'windows\services\session\SessionService.qml'
$serviceCode = (Get-Content -LiteralPath $serviceSource | ForEach-Object { $_ -replace '//.*$', '' }) -join "`n"
$fallbackPaths = @([regex]::Matches($serviceCode, 'execDetached|\bProcess\s*\{|createProcess|spawnProcess'))
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name session `
    -Sources @('windows/services/session/SessionService.qml',
        'windows/services/session/SessionServiceTest.qml') `
    -FixtureFile 'windows/services/session/SessionServiceTest.qml' -Marker CAELESTIA_SESSION_FIXTURE -MinimumAssertions 140

# The QML fixture covers the service's gate, dispatch and no-fallback surface.
# These read the shell and launcher side of the same path, which the Services
# suite can check without starting a shell.
$managerSource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\imports\Caelestia\Services\SessionManager.qml') -Raw
$backendSource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\services\session\NativeSessionBackend.qml') -Raw
$contentSource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\modules\session\Content.qml') -Raw
$nexusSource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\modules\nexus\pages\ServicesPage.qml') -Raw
$startSource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\scripts\Start-Caelestia.ps1') -Raw
$entrySource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\scripts\Start-CaelestiaEntry.ps1') -Raw
$versionsSource = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\scripts\Caelestia-Versions.ps1') -Raw
$fallbackGuard = $contentSource.IndexOf('SessionManager.allowDetachedFallback === false')
$detachedCall = $contentSource.IndexOf('Quickshell.execDetached')
$switchBackBody = [regex]::Match($contentSource, 'function switchBack\(\): void \{(?<body>[^}]*)\}').Groups['body'].Value
$switchBackChecks = [ordered]@{
    serviceHasNoProcessPath = $fallbackPaths.Count -eq 0
    managerGatesActions = $managerSource -match 'sessionActionGating:\s*true'
    managerDisablesDetachedFallback = $managerSource -match 'allowDetachedFallback:\s*false'
    sessionMenuLabelsSwitchBack = $contentSource -match 'Switch back to Windows'
    sessionMenuDispatchesSwitchBack = $contentSource -match 'SessionManager\.exec\(\["switch-back"\]\)'
    sessionMenuSwitchBackHasNoDetachedFallback = [bool]$switchBackBody -and $switchBackBody -notmatch 'execDetached'
    sessionMenuKeepsFallbackGuarded = $fallbackGuard -ge 0 -and $detachedCall -gt $fallbackGuard
    backendStartsDetachedLauncher = ($backendSource -match 'startDetached\(\)') -and ($backendSource -notmatch 'execDetached')
    backendRunsExistingQuit = $backendSource -match '"-Command"\s*,\s*"Quit"'
    nexusHasSwitchBack = $nexusSource -match 'Switch back to Windows'
    nexusDispatchesSwitchBack = $nexusSource -match 'SessionManager\.exec\(\["switch-back"\]\)'
    launcherAnswersAutostartStatus = $startSource -match "'AutostartStatus'"
    launcherDisablesAutostartForQuit = $startSource -match '\$DisableAutostart' -and $startSource -match 'Disable-CaelestiaAutostartForQuit'
    launcherReadsExistingRegistration = $startSource -match 'Test-CaelestiaAutostart'
    stableRootAnswersAutostartStatus = $entrySource -match "'AutostartStatus'"
    stableRootDisablesAutostartForQuit = $entrySource -match '\$DisableAutostart' -and
        $entrySource -match 'Disable-CaelestiaAutostartForQuit'
    registrationHasAutostartHelpers = ($versionsSource -match 'function Get-CaelestiaAutostartValue') -and
        ($versionsSource -match 'function Set-CaelestiaAutostart') -and
        ($versionsSource -match 'function Test-CaelestiaAutostart')
    registrationUsesSingleLaunchCommand = $versionsSource -match 'Get-CaelestiaAutostartValue \$Prefix' -and
        $versionsSource -match 'New-CaelestiaHiddenCommand'
}
$structuralFailures = @($switchBackChecks.Keys | Where-Object { -not $switchBackChecks[$_] })
$result.fallbackPaths = $fallbackPaths.Count
$result.switchBack = $switchBackChecks
$result.switchBackFailures = $structuralFailures
$result.passed = $result.passed -and $fallbackPaths.Count -eq 0 -and $structuralFailures.Count -eq 0
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
