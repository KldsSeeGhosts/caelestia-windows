#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-SemVer.ps1"
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$count = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message }; $script:count++ }
foreach ($version in @('0.0.0', '1.2.3+001', '1.2.3-a-b.0+foo.BAR', '99999999999999999999999999999.0.0',
    '1.2.3-999999999999999999999999999999999999999999999999')) {
    Assert ((ConvertTo-CaelestiaSemVer $version).Version -ceq $version) "Rejected valid SemVer $version"
}
foreach ($version in @('', 'v1.2.3', '1.2', '01.2.3', '1.02.3', '1.2.03', '1.2.3-01',
    '1.2.3-a.00', '1.2.3+', '1.2.3-', '1.2.3-a..b', '1.2.3+foo..bar', '1.2.3 ', '1.2.3-a_')) {
    $rejected = $false
    try { $null = ConvertTo-CaelestiaSemVer $version } catch { $rejected = $true }
    Assert $rejected "Accepted invalid SemVer $version"
}
$ordered = @('0.1.0-preview.2', '0.2.0-dev.1.9.1', '0.2.0-dev.1.10.1', '0.2.0-dev.2.1.1',
    '0.2.0-preview.1', '0.2.0-rc.1', '0.2.0', '0.2.1', '0.10.0', '1.0.0')
for ($i = 1; $i -lt $ordered.Count; $i++) {
    Assert ((Compare-CaelestiaSemVer $ordered[$i-1] $ordered[$i]) -eq -1) 'Incorrect forward precedence.'
    Assert ((Compare-CaelestiaSemVer $ordered[$i] $ordered[$i-1]) -eq 1) 'Incorrect reverse precedence.'
}
foreach ($pair in @(
    @('1.2.3+a', '1.2.3+b'), @('1.0.0-999999999999999999999999999999', '1.0.0-1000000000000000000000000000000'),
    @('1.0.0-1', '1.0.0-a'), @('1.0.0-A', '1.0.0-a'), @('1.0.0-a', '1.0.0-a.0'))) {
    $expected = if ($pair[0].Contains('+')) { 0 } else { -1 }
    Assert ((Compare-CaelestiaSemVer $pair[0] $pair[1]) -eq $expected) 'SemVer identifiers/metadata precedence failed.'
}
Assert (Test-CaelestiaDevVersion '0.2.0-dev.1.123456789012345678901234567890.2') 'Artificial dev sequence limit.'
Assert (-not (Test-CaelestiaDevVersion '0.2.0-dev.1.1.1+metadata')) 'Publish format accepted build metadata.'
$version = Read-CaelestiaVersion "$repo\windows\release\version.json"
foreach ($tag in @(& git -C $repo tag --list 'v*')) {
    try { $tagVersion = ConvertTo-CaelestiaSemVer $tag.Substring(1) } catch { continue }
    Assert ((Compare-CaelestiaSemVer $version.version $tagVersion.Core) -ge 0) 'Version source predates public history.'
}
Assert ((Get-Content "$repo\CHANGELOG.md" -Raw) -match '(?m)^## \[Unreleased\]') 'Missing Unreleased changelog.'
& cmake -P "$repo\cmake\CaelestiaVersion.cmake"
Assert ($LASTEXITCODE -eq 0) 'CMake authoritative reader failed.'
$ErrorActionPreference = 'Continue'
& cmake -DVERSION=9.9.9 -P "$repo\cmake\CaelestiaVersion.cmake" 2>$null
$ErrorActionPreference = 'Stop'
Assert ($LASTEXITCODE -ne 0) 'CMake accepted a mismatched override.'
$global:LASTEXITCODE = 0
Write-Output "PASS versioning: $count assertions."
