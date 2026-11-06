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
    foreach ($name in @('vcToolsVersion', 'vcCompilerFileVersion', 'vcLinkerFileVersion',
        'vcRedistDirectoryVersion', 'vcRedistVersion', 'windowsSdkVersion', 'clangVersion', 'clangTarget', 'rustVersion',
        'rustCommit', 'cargoVersion', 'rustTarget', 'qtVersion', 'qtCompilerFileVersion', 'qtLinkerFileVersion',
        'cmakeVersion', 'ninjaVersion', 'cli11Version')) { $receipt[$name] = $spec.$name }
    return [pscustomobject]$receipt
}
$receipt = New-SupportedReceipt
Assert-CaelestiaToolchainReceipt $receipt
Assert-True ($receipt.runtimeMinimum -eq '14.44.35211.0') 'The reviewed runtime floor must not silently change.'
foreach ($name in @('vcToolsVersion', 'vcCompilerFileVersion', 'vcLinkerFileVersion',
    'vcRedistDirectoryVersion', 'vcRedistVersion', 'windowsSdkVersion', 'clangVersion', 'clangTarget', 'rustVersion',
    'rustCommit', 'cargoVersion', 'rustTarget', 'qtVersion', 'qtCompilerFileVersion', 'qtLinkerFileVersion',
    'cmakeVersion', 'ninjaVersion', 'cli11Version')) {
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
foreach ($name in @('vcCompilerFileVersion', 'vcLinkerFileVersion', 'vcRedistVersion',
    'vcRedistDirectoryVersion', 'rustCommit', 'qtCompilerFileVersion', 'qtLinkerFileVersion')) {
    $bad = New-SupportedReceipt
    $bad.PSObject.Properties.Remove($name)
    Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } "Unsupported toolchain $name"
}
$bad = New-SupportedReceipt
$bad.vcRedistVersion = '14.44.35213.0'
Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } 'vcRedistVersion'
# Validly formatted, same-family substitutions must fail too. Checking only
# version/hash syntax would not enforce the qualified supplier identities.
foreach ($pair in @(
    @('vcCompilerFileVersion', '19.44.35230.0'),
    @('vcLinkerFileVersion', '14.44.35230.0'),
    @('rustCommit', ('0' * 40)))) {
    $bad = New-SupportedReceipt
    $bad.($pair[0]) = $pair[1]
    Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } "Unsupported toolchain $($pair[0])"
}
$bad = New-SupportedReceipt
$bad.runtimeMinimum = '14.50.0.0'
Assert-Rejected { Assert-CaelestiaToolchainReceipt $bad } 'runtime prerequisite'
# Ensure even an intentional spec edit cannot accidentally remove the floor guard.
$futureSpec = $spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$futureSpec.vcRedistVersion = '14.44.35213.0'
$bad = New-SupportedReceipt
$bad.vcRedistVersion = $futureSpec.vcRedistVersion
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
    function New-VersionedFixture([string]$Version) {
        # Real PE file-version resources without VS, SDK or native compiler
        # prerequisites. These assemblies are inspected, never executed.
        $id = [guid]::NewGuid().ToString('N')
        $file = Join-Path $testRoot "$id.dll"
        Add-Type -OutputAssembly $file -TypeDefinition @"
using System.Reflection;
[assembly: AssemblyFileVersion("$Version")]
public class Fixture_$id {}
"@
        return $file
    }
    $qualifiedBinary = New-VersionedFixture $spec.vcRedistVersion
    $servicedBinary = New-VersionedFixture '14.44.35213.0'
    $supplierRoot = Join-Path $testRoot 'supplier-vs'
    $marker = Join-Path $supplierRoot 'VC\Auxiliary\Build\Microsoft.VCRedistVersion.default.txt'
    $crtRoot = Join-Path $supplierRoot "VC\Redist\MSVC\$($spec.vcRedistDirectoryVersion)\x64\Microsoft.VC143.CRT"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker), $crtRoot | Out-Null
    $spec.vcRedistDirectoryVersion | Set-Content -LiteralPath $marker
    foreach ($name in @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
        'msvcp140_atomic_wait.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        Copy-Item -LiteralPath $qualifiedBinary -Destination (Join-Path $crtRoot $name)
    }
    $supplier = Get-CaelestiaVCRedist -VsRoot $supplierRoot
    Assert-True ($supplier.version -eq $spec.vcRedistVersion) 'Use actual CRT DLL metadata, not the differently numbered redist folder.'
    Assert-True ((Assert-CaelestiaReleaseVCRedist (New-SupportedReceipt) $crtRoot) -eq $crtRoot) 'Release and build must resolve the same marker-qualified supplier.'
    foreach ($name in @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
        'msvcp140_atomic_wait.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $path = Join-Path $crtRoot $name
        Remove-Item -LiteralPath $path
        Assert-Rejected { Get-CaelestiaVCRedist -VsRoot $supplierRoot } "Missing toolchain supplier file: $([regex]::Escape($name))"
        Copy-Item -LiteralPath $servicedBinary -Destination $path
        Assert-Rejected { Get-CaelestiaVCRedist -VsRoot $supplierRoot } 'Unsupported VC CRT.*14.44.35213.0'
        Copy-Item -LiteralPath $qualifiedBinary -Destination $path -Force
    }
    Remove-Item -LiteralPath $marker
    Assert-Rejected { Get-CaelestiaVCRedist -VsRoot $supplierRoot } 'Missing VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt'
    '14.44.99999' | Set-Content -LiteralPath $marker
    Assert-Rejected { Get-CaelestiaVCRedist -VsRoot $supplierRoot } 'Unsupported VC redist marker'
    $spec.vcRedistDirectoryVersion | Set-Content -LiteralPath $marker
    $newestRoot = Join-Path $supplierRoot 'VC\Redist\MSVC\14.44.99999\x64\Microsoft.VC143.CRT'
    New-Item -ItemType Directory -Force -Path $newestRoot | Out-Null
    Assert-True ((Get-CaelestiaVCRedist -VsRoot $supplierRoot).root -eq $crtRoot) 'A newer redist directory must not override the selected marker.'
    Assert-Rejected { Get-CaelestiaVCRedist -RuntimeRoot $newestRoot } 'does not match the selected VS redist marker'

    $qtRoot = Join-Path $testRoot 'qt'
    New-Item -ItemType Directory -Path (Join-Path $qtRoot 'sbom') | Out-Null
    foreach ($module in $spec.qtDownloads.module) {
        [ordered]@{ components = @(
            @{ name = 'Compiler MSVC'; version = $spec.qtCompilerFileVersion },
            @{ name = 'Linker MSVC'; version = $spec.qtLinkerFileVersion }
        ) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $qtRoot "sbom\$module-$($spec.qtVersion).cdx.json")
    }
    Assert-True ((Get-CaelestiaQtSupplier $qtRoot).compiler -eq $spec.qtCompilerFileVersion) 'Assert supplier tool metadata for every selected Qt package.'
    '{"components":[]}' | Set-Content -LiteralPath (Join-Path $qtRoot "sbom\qttools-$($spec.qtVersion).cdx.json")
    Assert-Rejected { Get-CaelestiaQtSupplier $qtRoot } 'Unsupported Qt qttools supplier'

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
    $message = & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot
    Assert-True ($message -eq 'Supported build toolchain and runtime receipt.') 'The assembler must accept a supported receipt.'
    $build.toolchain.vcToolsVersion = '14.50.12345'
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } 'vcToolsVersion'
    $build.toolchain = New-SupportedReceipt
    $build.toolchain.rustVersion = 'stable'
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } 'rustVersion'
    $build.toolchain = New-SupportedReceipt
    $build.toolchain.contractSha256 = '0' * 64
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } 'another specification'
    $build.toolchain = New-SupportedReceipt
    $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
    Copy-Item -LiteralPath $servicedBinary -Destination (Join-Path $crtRoot 'vcruntime140_1.dll') -Force
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } 'Unsupported VC CRT vcruntime140_1.dll'
    Copy-Item -LiteralPath $qualifiedBinary -Destination (Join-Path $crtRoot 'vcruntime140_1.dll') -Force
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $newestRoot } 'does not match the selected VS redist marker'
    Remove-Item -LiteralPath (Join-Path $crtRoot 'msvcp140.dll')
    Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } 'Missing toolchain supplier file: msvcp140.dll'
    Copy-Item -LiteralPath $qualifiedBinary -Destination (Join-Path $crtRoot 'msvcp140.dll')
    foreach ($name in @('vcCompilerFileVersion', 'vcLinkerFileVersion', 'vcRedistVersion', 'rustCommit')) {
        $build.toolchain = New-SupportedReceipt
        $build.toolchain.PSObject.Properties.Remove($name)
        $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
        Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } "Unsupported toolchain $name"
    }
    foreach ($pair in @(
        @('vcCompilerFileVersion', '19.44.35230.0'),
        @('vcLinkerFileVersion', '14.44.35230.0'),
        @('rustCommit', ('0' * 40)))) {
        $build.toolchain = New-SupportedReceipt
        $build.toolchain.($pair[0]) = $pair[1]
        $build | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'build.json') -Encoding UTF8
        Assert-Rejected { & $assembler -BuildRoot $testRoot -ValidateToolchainOnly -VCRuntimeRoot $crtRoot } "Unsupported toolchain $($pair[0])"
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolved) -ne $tempRoot -or
        (Split-Path -Leaf $resolved) -notmatch '^caelestia-toolchain-test-[a-f0-9]{32}$') { throw 'Unsafe toolchain fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "PASS toolchain contract ($script:assertions assertions)"
