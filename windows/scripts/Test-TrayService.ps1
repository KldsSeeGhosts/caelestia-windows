[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$serviceSource = Join-Path $repoRoot 'windows\services\tray\TrayService.qml'
# Comments may name the backend; only code-level singleton/type usage counts.
$nativeReferences = @(Select-String -LiteralPath $serviceSource -Pattern '\bSystemTray\.|\bproperty\s+SystemTrayItem\b')
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name tray `
    -Sources @('windows/services/tray/TrayService.qml',
        'windows/services/tray/TrayServiceTest.qml') `
    -FixtureFile 'windows/services/tray/TrayServiceTest.qml' -Marker CAELESTIA_TRAY_FIXTURE -MinimumAssertions 70
$result.nativeReferences = @($nativeReferences | ForEach-Object { $_.Line.Trim() })
$result.passed = $result.passed -and $nativeReferences.Count -eq 0
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
