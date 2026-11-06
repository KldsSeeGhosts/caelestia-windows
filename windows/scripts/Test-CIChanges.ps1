[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-ci-scope-' + [guid]::NewGuid().ToString('N'))
$oldOutput = $env:GITHUB_OUTPUT
New-Item -ItemType Directory -Path $root | Out-Null
function Invoke-FixtureGit([string[]]$Arguments) {
    $output = & git -C $root @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'CI-scope Git fixture failed.' }
    return $output
}
function Commit-Fixture {
    $null = Invoke-FixtureGit @('add', '--all')
    $null = Invoke-FixtureGit @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '--quiet', '-m', 'fixture')
}
function Assert-Scope([string]$Base, [string]$Event, [bool]$Expected) {
    $env:GITHUB_OUTPUT = Join-Path "$root\.git" ('result-' + [guid]::NewGuid().ToString('N'))
    & "$PSScriptRoot\..\ci\Get-NativeBuildRequired.ps1" -RepoRoot $root -Base $Base -EventName $Event | Out-Null
    $actual = (Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw).Trim()
    if ($actual -ne ('native=' + $Expected.ToString().ToLowerInvariant())) { throw "Incorrect native-build decision for $Event." }
}
try {
    $null = Invoke-FixtureGit @('init', '--quiet')
    'fixture' | Set-Content -LiteralPath "$root\README.md"
    Commit-Fixture
    $base = (Invoke-FixtureGit @('rev-parse', 'HEAD')).Trim()
    Assert-Scope '' 'push' $true
    Assert-Scope ('0' * 40) 'push' $true
    Assert-Scope ('1' * 40) 'push' $true
    Assert-Scope $base 'workflow_dispatch' $true
    Assert-Scope $base 'pull_request' $true
    'docs only' | Add-Content -LiteralPath "$root\README.md"
    Commit-Fixture
    Assert-Scope $base 'pull_request' $false
    New-Item -ItemType Directory -Path "$root\windows\shell" -Force | Out-Null
    'fixture runtime change' | Set-Content -LiteralPath "$root\windows\shell\shell.qml"
    Commit-Fixture
    Assert-Scope $base 'pull_request' $true
    $base = (Invoke-FixtureGit @('rev-parse', 'HEAD')).Trim()
    'unknown path' | Set-Content -LiteralPath "$root\new-file.txt"
    Commit-Fixture
    Assert-Scope $base 'push' $true
    Write-Output 'PASS CI scope: only known documentation changes skip native validation; unknown inputs build.'
} finally {
    $env:GITHUB_OUTPUT = $oldOutput
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-ci-scope-*') { throw 'Unsafe CI-scope fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
