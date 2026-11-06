#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
if ($OutputRoot -eq $repo -or $OutputRoot.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $repo.StartsWith($OutputRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $OutputRoot)) {
    throw 'Choose a new capture-release fixture output outside the checkout.'
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$bootstrap = Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'
$text = Get-Content -LiteralPath $bootstrap -Raw
$requiredBlock = [regex]::Match($text, 'foreach \(\$required in @\(([\s\S]*?)\n    \)\)')
if (-not $requiredBlock.Success) { throw 'Release required-file inventory was not found.' }
$required = @([regex]::Matches($requiredBlock.Groups[1].Value, '[''"]([^''"]+)[''"]') |
    ForEach-Object { $_.Groups[1].Value })
$source = 'a' * 40
$origin = '37f795041cbbb32ed46cba103f3f000a3a99ac13'
$lock = Get-Content -LiteralPath "$repo\windows\sources.lock.json" -Raw | ConvertFrom-Json
$results = @()
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Get-ReleaseFunction([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Capture provenance source has a parse error.' }
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-CaelestiaCaptureRelease'
    }, $true))
    if ($functions.Count -ne 1) { throw 'Expected one pure capture release provenance helper.' }
    $functions[0].Extent.Text.Replace("`r`n", "`n")
}
Assert-True ((Get-ReleaseFunction "$repo\windows\capture\Source.ps1") -ceq (Get-ReleaseFunction $bootstrap)) `
    'Standalone bootstrap must retain the exact shared pure-data validator.'
function Refresh-Files($Case) {
    $Case.manifest.files = @(Get-ChildItem -LiteralPath $Case.root -Recurse -File |
        Where-Object Name -ne 'release.json' | Sort-Object FullName | ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($Case.root.Length + 1).Replace('\', '/')
                size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            }
        })
}
function New-Bundle([string]$Name, [switch]$Legacy, [switch]$NoOrigin) {
    $root = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    $exe = if ($Legacy) { 'glazier.exe' } else { 'caelestia-capture.exe' }
    foreach ($relative in $required) {
        $path = Join-Path $root $relative.Replace('$captureExecutable', $exe)
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        # Never executed. In particular, the maintenance file throws if
        # bootstrap accidentally imports supplied code in -VerifyOnly mode.
        [IO.File]::WriteAllText($path, "throw 'Synthetic bundle code must not execute during verification.'")
    }
    Copy-Item -LiteralPath $bootstrap -Destination "$root\Install-CaelestiaRelease.ps1" -Force
    $header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    [IO.File]::WriteAllText("$root\payload\shell\shell.qml", $header + "// Synthetic, never launched.`n")
    $dependencies = [ordered]@{
        quickshell = @{ revision = 'b' * 40 }; m3shapes = @{ revision = 'd' * 40 }
    }
    if ($Legacy) {
        $dependencies.glazier = @{ revision = $origin }
        [IO.File]::WriteAllText("$root\payload\licenses\sources.lock.json", '{"glazier":{"revision":"' + $origin + '"}}')
    } else {
        $dependencies.capture = [pscustomobject]@{
            representation = 'in-tree'; path = 'windows/capture'; sourceRevision = $source
            originRepository = 'https://github.com/KldsSeeGhosts/glazier.git'; originRevision = $origin
            cargoLockSha256 = $lock.glazier.cargoLockSha256; executable = $exe
            sha256 = (Get-FileHash -LiteralPath "$root\payload\$exe").Hash.ToLowerInvariant()
        }
        [IO.File]::WriteAllText("$root\payload\licenses\sources.lock.json", ($lock | ConvertTo-Json -Depth 12))
        if (-not $NoOrigin) {
            [IO.File]::WriteAllText("$root\payload\licenses\Caelestia-Capture-ORIGIN.md", 'Synthetic origin notice.')
        }
    }
    $case = [pscustomobject]@{
        root = $root
        manifest = [pscustomobject]@{
            schema = 'caelestia-windows-release'; version = 1; platform = 'windows-x64'
            sourceRevision = $source; nativeSourceRevision = $source; backendRevision = 'b' * 40
            releaseId = 'capture-fixture'; dependencies = $dependencies; files = @()
            relocation = 'profile-pragmas-v1'
            prerequisites = @{ visualCppRuntime = @{
                deployment = 'system'; architecture = 'x64'; minimumVersion = '14.44.35211.0'
                downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
            }}
        }
    }
    Refresh-Files $case
    return $case
}
function Invoke-Verification($Case, [string]$ExpectedFailure = '') {
    $manifest = Join-Path $Case.root 'release.json'
    $Case.manifest | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $hash = (Get-FileHash -LiteralPath $manifest).Hash
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe -NoProfile -NonInteractive -File $bootstrap `
            -BundleRoot $Case.root -ExpectedManifestSha256 $hash -VerifyOnly 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $name = Split-Path -Leaf $Case.root
    $output | Set-Content -LiteralPath "$OutputRoot\$name.private.log" -Encoding UTF8
    if ($ExpectedFailure) {
        Assert-True ($exitCode -ne 0 -and ($output -join "`n") -match $ExpectedFailure) "Expected release refusal: $name"
    } else { Assert-True ($exitCode -eq 0) "Expected verified release: $name" }
    $script:results += [ordered]@{ case = $name; outcome = 'pass'; expectedRefusal = $ExpectedFailure; exitCode = $exitCode }
}
Invoke-Verification (New-Bundle 'first-party-valid')
Invoke-Verification (New-Bundle 'legacy-valid' -Legacy)
foreach ($field in @('representation', 'path', 'sourceRevision', 'originRepository', 'originRevision',
    'cargoLockSha256', 'executable', 'sha256')) {
    $case = New-Bundle "descriptor-$field"
    $case.manifest.dependencies.capture.$field = 'invalid'
    Invoke-Verification $case 'Invalid first-party capture release provenance'
}
$case = New-Bundle 'native-source-mismatch'
$case.manifest.nativeSourceRevision = 'c' * 40
Invoke-Verification $case 'Invalid first-party capture release provenance'
$case = New-Bundle 'lock-mismatch'
$changedLock = $lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$changedLock.glazier.cargoLockSha256 = '0' * 64
[IO.File]::WriteAllText("$($case.root)\payload\licenses\sources.lock.json", ($changedLock | ConvertTo-Json -Depth 12))
Refresh-Files $case
Invoke-Verification $case 'bundled source lock disagree'
Invoke-Verification (New-Bundle 'missing-origin' -NoOrigin) 'origin notice'
$case = New-Bundle 'duplicate-helper'
[IO.File]::WriteAllText("$($case.root)\payload\glazier.exe", 'Never executed legacy fixture.')
Refresh-Files $case
Invoke-Verification $case 'single helper identity'
$case = New-Bundle 'binary-corruption'
[IO.File]::WriteAllText("$($case.root)\payload\caelestia-capture.exe", 'Corrupt fixture bytes.')
Invoke-Verification $case 'corrupt release file'
[ordered]@{
    schemaVersion = 1; suite = 'capture-release-verification'; result = 'pass'
    sourceRevision = (& git -C $repo rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repo status --porcelain)
    assertions = $results.Count + 1; cases = $results
    evidenceClass = 'synthetic-verify-only-no-install'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$OutputRoot\capture-release.json" -Encoding UTF8
Write-Output "PASS capture release provenance ($($results.Count + 1) assertions; VerifyOnly, no installation)"
