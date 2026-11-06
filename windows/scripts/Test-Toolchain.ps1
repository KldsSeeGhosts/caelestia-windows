#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
$spec = Get-CaelestiaToolchain
$script:assertions = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    Assert-True ($caught -and $caught -match $Pattern) "Expected actionable rejection '$Pattern', got '$caught'."
}
function New-SupportedReceipt {
    $receipt = [ordered]@{
        schemaVersion = 1; contractId = $spec.id; contractSha256 = Get-CaelestiaToolchainHash
        runtimeMinimum = $spec.runtimeMinimum
    }
    foreach ($name in @('vcToolsVersion', 'windowsSdkVersion', 'clangVersion', 'clangTarget', 'rustVersion',
        'cargoVersion', 'rustTarget', 'qtVersion', 'cmakeVersion', 'ninjaVersion', 'cli11Version')) { $receipt[$name] = $spec.$name }
    return [pscustomobject]$receipt
}
$receipt = New-SupportedReceipt
Assert-CaelestiaToolchainReceipt $receipt
Assert-True ($receipt.runtimeMinimum -eq '14.44.35211.0') 'The reviewed runtime floor must not silently change.'
foreach ($name in @('vcToolsVersion', 'windowsSdkVersion', 'clangVersion', 'clangTarget', 'rustVersion',
    'cargoVersion', 'rustTarget', 'qtVersion', 'cmakeVersion', 'ninjaVersion', 'cli11Version')) {
    $bad = New-SupportedReceipt
    $bad.$name = 'incompatible'
    Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } "Unsupported toolchain $name"
}
foreach ($name in @('contractId', 'contractSha256', 'schemaVersion')) {
    $bad = New-SupportedReceipt
    $bad.$name = 'unknown'
    Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } 'another specification'
}
$bad = New-SupportedReceipt
$bad.PSObject.Properties.Remove('rustVersion')
Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } 'rustVersion'
$bad = New-SupportedReceipt
$bad.runtimeMinimum = '14.50.0.0'
Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } 'runtime prerequisite'
# Ensure even an intentional spec edit cannot accidentally remove the floor guard.
$futureSpec = $spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$futureSpec.vcToolsVersion = '14.50.12345'
$bad = New-SupportedReceipt
$bad.vcToolsVersion = $futureSpec.vcToolsVersion
Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad $futureSpec } 'runtime prerequisite'
$build = [pscustomobject]@{
    toolchain = New-SupportedReceipt; msvcToolsVersion = $spec.vcToolsVersion
    windowsSdkVersion = $spec.windowsSdkVersion; qtVersion = $spec.qtVersion
}
Assert-CaelestiaBuildToolchain $build
$build.msvcToolsVersion = '14.50.12345'
Assert-Rejected { Assert-CaelestiaBuildToolchain $build } 'disagrees'
Assert-Rejected { Assert-CaelestiaBuildToolchain ([pscustomobject]@{}) } 'Receipt|receipt'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-toolchain-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $older = Join-Path $testRoot 'vs-older'
    $newer = Join-Path $testRoot 'vs-newer'
    $bin = Join-Path $older "VC\Tools\MSVC\$($spec.vcToolsVersion)\bin\Hostx64\x64"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $bin 'cl.exe') | Out-Null
    $instances = @(
        [pscustomobject]@{ installationPath = $newer; installationVersion = '18.0' },
        [pscustomobject]@{ installationPath = $older; installationVersion = '17.14' })
    Assert-True ((Select-CaelestiaVisualStudio $instances).installationPath -eq $older) 'Select the retained toolset, not the latest VS banner.'
    Assert-Rejected { Select-CaelestiaVisualStudio @($instances[0]) } 'Missing VC tools 14.44.35207'
    $archive = Join-Path $testRoot 'archive.bin'
    [IO.File]::WriteAllText($archive, 'synthetic public download fixture')
    $hash = (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant()
    Assert-CaelestiaDownload $archive $hash
    Assert-Rejected { Assert-CaelestiaDownload $archive ('0' * 64) } 'checksum mismatch'
    Assert-Rejected { Assert-CaelestiaDownload (Join-Path $testRoot 'missing.bin') $hash } 'missing archive'

    # Exercise the assembler's real entry point, without package/installer writes.
    $logs = Join-Path $testRoot 'logs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    $build.msvcToolsVersion = $spec.vcToolsVersion
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    $assembler = Join-Path $PSScriptRoot 'New-CaelestiaRelease.ps1'
    $message = & $assembler -BuildRoot $testRoot -ValidateToolchainOnly
    Assert-True ($message -eq 'Supported build toolchain and runtime receipt.') 'The assembler must accept a supported receipt.'
    $build.toolchain.vcToolsVersion = '14.50.12345'
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly } 'vcToolsVersion'
    $build.toolchain = New-SupportedReceipt
    $build.toolchain.rustVersion = 'stable'
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly } 'rustVersion'
    $build.toolchain = New-SupportedReceipt
    $build.toolchain.contractSha256 = '0' * 64
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly } 'another specification'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolved) -ne $tempRoot -or
        (Split-Path -Leaf $resolved) -notmatch '^caelestia-toolchain-test-[a-f0-9]{32}$') { throw 'Unsafe toolchain fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "PASS toolchain contract ($script:assertions assertions)"
