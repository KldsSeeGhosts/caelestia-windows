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
    -FixtureFile 'windows/services/session/SessionServiceTest.qml' -Marker CAELESTIA_SESSION_FIXTURE -MinimumAssertions 120
$result.fallbackPaths = $fallbackPaths.Count
$result.passed = $result.passed -and $fallbackPaths.Count -eq 0
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
