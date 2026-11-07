#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
. "$repo\windows\capture\Source.ps1"
$script:assertions = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    $script:assertions++
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected capture refusal: $Pattern"
}
$source = Get-CaelestiaCaptureSource $repo
Assert-True ($source.sourceRevision -ceq (& git -C $repo rev-parse HEAD).Trim()) 'Capture revision must be actual shell HEAD.'
Assert-True ($source.originRevision -cne $source.sourceRevision) 'Origin is not maintained capture revision.'
Assert-True ($source.cargoLockSha256 -ceq '334db81cddfdb2020dd6738b0acc10a449bfb22178a425ac882501ea61b16f70') 'Imported lock unchanged.'
foreach ($inputPath in @('windows/capture/src/main.rs', 'windows/capture/assets/tabler-icons.ttf',
    'windows/capture/Source.ps1', 'windows/capture/docs/control-protocol.md', 'windows/deps/quickshell',
    'windows/sources.lock.json', 'elsewhere/implementation.rs', 'windows/toolchain.json',
    'windows/scripts/Build-Prototype.ps1')) {
    Assert-True (Test-CaelestiaCaptureNativeInput $inputPath) "Native reuse must refuse: $inputPath"
}
Assert-True (-not (Test-CaelestiaCaptureNativeInput 'windows/shell/shell.qml')) 'QML-only reuse remains possible.'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-capture-contract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture\windows\capture" -Force | Out-Null
# Kept as a small owned evidence fixture. No recursive cleanup or user files.
$exe = "$fixture\caelestia-capture.exe"
[IO.File]::WriteAllText($exe, 'synthetic capture payload, never executable')
function New-BuildReceipt {
    return [pscustomobject]@{
        sourceRevision = $source.sourceRevision
        captureSourceRevision = $source.sourceRevision; captureSourcePath = $source.relativePath
        captureOriginRevision = $source.originRevision; captureCargoLockSha256 = $source.cargoLockSha256
        captureExecutable = $source.executable; captureBundled = $true
        captureSha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    }
}
Assert-CaelestiaCaptureBuild (New-BuildReceipt) $source $exe
$script:assertions++
foreach ($field in @('captureSourceRevision', 'captureSourcePath', 'captureOriginRevision',
    'captureCargoLockSha256', 'captureExecutable', 'captureSha256')) {
    $bad = New-BuildReceipt
    $bad.$field = 'not-the-built-input'
    Assert-Rejected { Assert-CaelestiaCaptureBuild $bad $source $exe } 'exact first-party capture'
}
$bad = New-BuildReceipt
$bad.captureBundled = $false
Assert-Rejected { Assert-CaelestiaCaptureBuild $bad $source $exe } 'exact first-party capture'
$bad = New-BuildReceipt
[IO.File]::WriteAllText($exe, 'changed bytes')
Assert-Rejected { Assert-CaelestiaCaptureBuild $bad $source $exe } 'does not match'
Copy-Item -LiteralPath "$repo\windows\sources.lock.json" -Destination "$fixture\windows\sources.lock.json"
Copy-Item -LiteralPath "$repo\windows\capture\Cargo.lock" -Destination "$fixture\windows\capture\Cargo.lock"
Add-Content -LiteralPath "$fixture\windows\capture\Cargo.lock" -Value '# corruption negative control'
Assert-Rejected { Get-CaelestiaCaptureSource $fixture } 'Cargo.lock does not match'
$workflow = Get-Content -LiteralPath "$repo\.github\workflows\windows-build.yml" -Raw
$mirror = Get-Content -LiteralPath "$repo\windows\ci\windows-build.yml.template" -Raw
Assert-True ($workflow.Replace("`r`n", "`n") -ceq $mirror.Replace("`r`n", "`n")) 'Workflow mirror must remain exact.'
Assert-True ($workflow.Contains('Test-CaptureRust.ps1') -and $workflow.Contains('C:/ci-capture/capture-rust.json')) 'Public gate and sanitized receipt upload required.'
Assert-True ((Get-Content "$PSScriptRoot\New-CaelestiaRelease.ps1" -Raw).Contains("if (`$build.backendMode -cne 'pinned')")) 'Candidate-release refusal guard must remain.'
& node "$repo\windows\tests\CaptureIntegration.test.js"
if ($LASTEXITCODE -ne 0) { throw 'Capture adapter integration checks failed.' }
& node "$repo\windows\tests\GlazierRecorderLogic.test.js"
if ($LASTEXITCODE -ne 0) { throw 'Existing recorder ownership checks failed.' }
Write-Output "PASS capture source/provenance contract ($script:assertions assertions)"
