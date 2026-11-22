[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
# Exercise the production staged-tree guard, including an upstream-style file
# outside the adapters. Nothing in these source-only controls is executed.
$controlRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-clipboard-guard-' + [guid]::NewGuid().ToString('N'))
$controlRoot = [IO.Path]::GetFullPath($controlRoot)
New-Item -ItemType Directory -Path $controlRoot | Out-Null
$ownedStage = Enter-QmlSharedStage
try {
    $stage = Join-Path $controlRoot 'stage'
    $profile = Join-Path $controlRoot 'profile'
    $sharedStage = $env:CAELESTIA_TEST_SHARED_STAGE
    if ($sharedStage -and (Test-Path -LiteralPath (Join-Path $sharedStage 'shell.qml') -PathType Leaf)) {
        # The baseline staged tree is immutable; only the guard loop below
        # needs fresh staging to prove the legacy-reference rejection.
        Copy-QmlStageOverlay $sharedStage $stage
    } else {
        & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot $profile | Out-Null
    }
    $control = Join-Path $stage 'LegacyClipboardControl.qml'
    foreach ($reference in @('Native.Clipboard', 'Quickshell.Windows.Clipboard')) {
        "import QtQuick`nQtObject { property var legacy: $reference }" |
            Set-Content -LiteralPath $control -Encoding UTF8
        $rejected = $false
        try {
            & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot $profile | Out-Null
        } catch {
            if ($_.Exception.Message -notlike 'Staged QML references the legacy clipboard singleton:*') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Staged clipboard guard accepted $reference." }
    }
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ($controlRoot.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $controlRoot) -like 'caelestia-clipboard-guard-*') {
        Remove-Item -LiteralPath $controlRoot -Recurse -Force
    }
    Exit-QmlSharedStage $ownedStage
}
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-backend-api -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/CaptureBackendApiTest.qml') -FixtureFile 'windows/tests/CaptureBackendApiTest.qml' `
    -Marker CAELESTIA_CAPTURE_BACKEND_API -MinimumAssertions 20
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture backend API fixture failed. See $($result.stderr)." }
