[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"

# A harmless installed-looking prefix. Fixtures replace the process launch with
# a recording fake, so this file is never executed and no live session or real
# HKCU Run key is touched.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-switchback-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
try {
    '# Fixture launcher. The handoff fixtures replace Process.startDetached().' |
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'Start-Caelestia.ps1') -Encoding UTF8
    '{"product":"caelestia-windows","version":1}' |
        Set-Content -LiteralPath (Join-Path $fixtureRoot 'install.json') -Encoding UTF8

    $environment = @{
        CAELESTIA_INSTALL_ROOT = $fixtureRoot
        CAELESTIA_SHELL_LIVE = '1'
        CAELESTIA_SHELL_SMOKE = '0'
        CAELESTIA_WINDOWS_SESSION = '1'
        CAELESTIA_WINDOWS_SESSION_ACTIONS = '1'
    }

    $handoff = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name session-handoff `
        -ShellFixture -UseQuickshell -Environment $environment `
        -Sources @('windows/tests/NativeSessionBackendHandoffTest.qml') `
        -FixtureFile 'windows/tests/NativeSessionBackendHandoffTest.qml' `
        -Marker CAELESTIA_SESSION_HANDOFF -MinimumAssertions 24 -TimeoutMs 30000 -LogSuffix 'handoff'

    $drawer = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name session-drawer `
        -ShellFixture -UseQuickshell -Environment $environment `
        -ShellConfig '{"session":{"vimKeybinds":true}}' `
        -Sources @('windows/tests/SessionDrawerKeyboardTest.qml') `
        -FixtureFile 'windows/tests/SessionDrawerKeyboardTest.qml' `
        -Marker CAELESTIA_SESSION_DRAWER -MinimumAssertions 40 -LogSuffix 'drawer'

    [ordered]@{
        handoff = $handoff
        drawer = $drawer
    } | ConvertTo-Json -Depth 8

    if (-not $handoff.passed) {
        throw "Session handoff fixture failed. See $($handoff.stderr)."
    }
    if (-not $drawer.passed) {
        throw "Session drawer fixture failed. See $($drawer.stderr)."
    }
} finally {
    $safe = [IO.Path]::GetFullPath($fixtureRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $safe.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $safe) -notlike 'caelestia-switchback-*') {
        throw 'Unsafe session fixture cleanup.'
    }
    Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction SilentlyContinue
}
