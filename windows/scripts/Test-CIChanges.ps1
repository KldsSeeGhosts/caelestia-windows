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
function Assert-Scope([string]$Base, [string]$Event, [string]$Expected) {
    $env:GITHUB_OUTPUT = Join-Path "$root\.git" ('result-' + [guid]::NewGuid().ToString('N'))
    & "$PSScriptRoot\..\ci\Get-NativeBuildRequired.ps1" -RepoRoot $root -Base $Base -EventName $Event | Out-Null
    $actual = (Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw).Trim()
    if ($actual -cne "native=$Expected") { throw "Incorrect native-build decision for $Event. Expected $Expected, got $actual." }
}
try {
    $null = Invoke-FixtureGit @('init', '--quiet')
    'fixture' | Set-Content -LiteralPath "$root\README.md"
    Commit-Fixture
    $base = (Invoke-FixtureGit @('rev-parse', 'HEAD')).Trim()
    Assert-Scope '' 'push' 'full'
    Assert-Scope ('0' * 40) 'pull_request' 'full'
    Assert-Scope ('1' * 40) 'pull_request' 'full'
    Assert-Scope $base 'workflow_dispatch' 'full'
    Assert-Scope $base 'pull_request' 'full'
    'docs only' | Add-Content -LiteralPath "$root\README.md"
    Commit-Fixture
    Assert-Scope $base 'pull_request' 'none'
    Assert-Scope $base 'push' 'full'
    New-Item -ItemType Directory -Path "$root\windows\shell" -Force | Out-Null
    'fixture runtime change' | Set-Content -LiteralPath "$root\windows\shell\shell.qml"
    Commit-Fixture
    Assert-Scope $base 'pull_request' 'reuse'
    Assert-Scope $base 'push' 'full'
    $base = (Invoke-FixtureGit @('rev-parse', 'HEAD')).Trim()
    foreach ($path in @('new-file.txt', '.github/workflows/test.yml', 'windows/ci/README.md',
        'windows/scripts/Test-Validation.ps1', 'windows/toolchain.json', 'windows/toolchain/tool.lock.txt',
        'windows/sources.lock.json', 'windows/deps/quickshell', '.gitmodules', 'plugin/new.qml',
        'native/main.cpp', 'native/main.rs', 'windows/shell/unknown.qml')) {
        $base = (Invoke-FixtureGit @('rev-parse', 'HEAD')).Trim()
        $target = Join-Path $root $path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        'unknown or native input' | Set-Content -LiteralPath $target
        Commit-Fixture
        Assert-Scope $base 'pull_request' 'full'
    }
    # A gitlink masquerading as a declared QML path must still compile fully.
    $base = (Invoke-FixtureGit @('rev-parse', 'HEAD')).Trim()
    $null = Invoke-FixtureGit @('update-index', '--add', '--cacheinfo', "160000,$base,windows/shell/shell.qml")
    $null = Invoke-FixtureGit @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
        'commit', '--quiet', '-m', 'gitlink negative control')
    Assert-Scope $base 'pull_request' 'full'
    Write-Output 'PASS CI scope: docs=none, declared shell inputs=reuse, native/unknown/non-PR=full.'
} finally {
    $env:GITHUB_OUTPUT = $oldOutput
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-ci-scope-*') { throw 'Unsafe CI-scope fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
