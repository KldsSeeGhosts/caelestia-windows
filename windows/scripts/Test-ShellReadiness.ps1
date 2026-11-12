[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name shell-readiness -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/ShellReadinessTest.qml') -FixtureFile 'windows/tests/ShellReadinessTest.qml' `
    -Marker CAELESTIA_SHELL_READINESS -MinimumAssertions 15
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Shell readiness fixture failed. See $($result.stderr)." }
# Exercise the real native log formatter/redactor and the production parser.
# A Qt qml.exe log or a marker on stderr cannot satisfy this contract.
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
$readiness = [Caelestia.Takeover.ShellReadiness]::new()
foreach ($line in [IO.File]::ReadAllLines($result.stdout)) { $readiness.Observe($line) }
if (-not $readiness.Ready) { throw 'Native stdout/redaction path lost the first-frame readiness marker.' }
