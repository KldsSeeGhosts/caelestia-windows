#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\Caelestia-Update.ps1"
Add-Type -AssemblyName System.IO.Compression
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-nexus-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$count = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message }; $script:count++ }
function Refuse([scriptblock]$Action, [string]$Name) {
    $rejected = $false; try { $null = & $Action } catch { $rejected = $true }
    Assert $rejected "Accepted negative control: $Name"
}
function New-Zip([string[]]$Names, [int]$Attributes = 0, [int]$Length = 20) {
    $path = Join-Path $root ([guid]::NewGuid().ToString('N') + '.zip')
    $file = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
    $archive = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Names) {
            $entry = $archive.CreateEntry($name)
            $entry.ExternalAttributes = $Attributes
            $stream = $entry.Open()
            try { $stream.Write([byte[]]::new($Length), 0, $Length) } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose(); $file.Dispose() }
    return $path
}
try {
    $manifest = Join-Path $root 'release.json'
    # Execute the existing producer's encoding choice, not just a hand-written
    # UTF8 fixture. Compatibility must not weaken network DSSE parsing.
    '{"releaseId":"0.2.0-dev.1.57.1"}' | Set-Content -LiteralPath $manifest -Encoding UTF8
    $manifestHash = (Get-FileHash -LiteralPath $manifest).Hash
    Assert ((Read-CaelestiaStrictJsonFile $manifest 16777216 -AllowUtf8Bom).releaseId -ceq '0.2.0-dev.1.57.1') 'Existing manifest BOM compatibility.'
    Refuse { Read-CaelestiaStrictJsonFile $manifest } 'network JSON BOM remains refused'
    Assert ((Get-FileHash -LiteralPath $manifest).Hash -ceq $manifestHash) 'Reading changed authenticated manifest bytes.'
    Refuse { Read-CaelestiaStrictJsonFile $manifest 2 -AllowUtf8Bom } 'JSON file allocation cap'
    foreach ($case in @(
        @{ names = @('root/../escape'); entries = 1; size = 20 },
        @{ names = @('/root/escape'); entries = 1; size = 20 },
        @{ names = @('C:/root/escape'); entries = 1; size = 20 },
        @{ names = @('root/a\b'); entries = 1; size = 20 },
        @{ names = @('root/CON.txt'); entries = 1; size = 20 },
        @{ names = @('root/a.'); entries = 1; size = 20 },
        @{ names = @('root/a '); entries = 1; size = 20 },
        @{ names = @('root/a', 'root/A'); entries = 2; size = 40 },
        @{ names = @('wrong/a'); entries = 1; size = 20 },
        @{ names = @('root/a'); entries = 2; size = 20 },
        @{ names = @('root/a'); entries = 1; size = 19 },
        @{ names = @('root/a'); entries = 1; size = 21 },
        @{ names = @('root/a', 'root/a/b'); entries = 2; size = 40 },
        @{ names = @('root/a'); entries = 1; size = 20; attributes = -1610612736 }, # Unix symlink
        @{ names = @('root/a'); entries = 1; size = 20; attributes = 1024 }, # reparse
        @{ names = @('root/a'); entries = 1; size = 20; attributes = 64 } # device
    )) {
        $zip = New-Zip $case.names ([int]$case.attributes)
        $destination = Join-Path $root ('extract-' + [guid]::NewGuid().ToString('N'))
        Refuse { Expand-CaelestiaUpdate $zip $destination 'root' $case.entries $case.size } ($case.names -join ',')
        Assert (-not (Test-Path -LiteralPath $destination)) 'Rejected ZIP wrote output before complete preflight.'
    }
    $zip = New-Zip @('root/zeros') 0 1048576
    $destination = Join-Path $root 'high-compression-valid'
    $bundle = Expand-CaelestiaUpdate $zip $destination 'root' 1 1048576
    Assert ((Get-Item -LiteralPath "$bundle\zeros").Length -eq 1048576) 'Authenticated highly compressible input was rejected.'
    foreach ($path in @('\\server\share\a', 'C:\', 'C:\a\..\b', 'C:\a\CON', 'C:\a\b:stream', 'C:\a\b.')) {
        Refuse { Assert-CaelestiaUpdatePath $path } "unsafe local path $path"
    }
    $target = Join-Path $root 'junction-target'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $junction = Join-Path $root 'junction'
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    try { Refuse { Assert-CaelestiaUpdatePath (Join-Path $junction 'child') } 'junction ancestor' }
    finally { [IO.Directory]::Delete($junction) }
    foreach ($uri in @('http://github.com/a', 'https://github.com:444/a', 'https://user@github.com/a',
        'https://github.com/a#fragment', 'https://evil.invalid/a')) {
        Refuse { [Caelestia.Update.Transport]::ValidateUri([uri]$uri, @('github.com')) } 'redirect/final-host URI'
    }
    [Caelestia.Update.Transport]::ValidateUri([uri]'https://release-assets.githubusercontent.com/a', @('release-assets.githubusercontent.com'))
    $count++
    $bytes = [byte[]](1, 2, 3)
    $hash = [Caelestia.Update.Security]::Hash($bytes)
    foreach ($case in @(
        @{ cap = 3; size = 3; hash = $hash; valid = $true },
        @{ cap = 2; size = 3; hash = $hash; valid = $false },
        @{ cap = 4; size = 4; hash = $hash; valid = $false },
        @{ cap = 3; size = 3; hash = ('0' * 64); valid = $false }
    )) {
        $inputStream = [IO.MemoryStream]::new($bytes)
        $outputStream = [IO.MemoryStream]::new()
        try {
            $action = { [Caelestia.Update.Transport]::CopyBounded($inputStream, $outputStream, $case.cap,
                $case.size, $case.hash, [Threading.CancellationToken]::None) }
            if ($case.valid) { & $action; Assert ($outputStream.Length -eq 3) 'Valid bounded copy failed.' }
            else { Refuse $action 'body overflow/underflow/hash' }
        } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    }
    $inputStream = [IO.MemoryStream]::new($bytes); $outputStream = [IO.MemoryStream]::new()
    $cancel = [Threading.CancellationTokenSource]::new()
    try {
        $cancel.Cancel()
        Refuse { [Caelestia.Update.Transport]::CopyBounded($inputStream, $outputStream, 3, 3, $hash, $cancel.Token) } 'body cancellation'
    } finally { $inputStream.Dispose(); $outputStream.Dispose(); $cancel.Dispose() }
    # The exact production lock implementation must be recursive on the same
    # thread, as used by updater -> installer, while retaining ownership.
    $prefix = Join-Path $root 'lock-prefix'
    $outer = Enter-CaelestiaInstallLock $prefix
    $inner = $null
    try {
        $inner = Enter-CaelestiaInstallLock $prefix
        Assert ($null -ne $outer -and $null -ne $inner) 'Same-thread nested installer deadlock.'
    } finally { Exit-CaelestiaInstallLock $inner; Exit-CaelestiaInstallLock $outer }
    # Exercise an explicitly unconfigured disposable installation, never the
    # configured shipped trust or real transport. Configured workers have
    # recording-transport coverage in Test-NexusWorker.
    $scripts = Join-Path $root 'scripts'
    Copy-Item -LiteralPath $PSScriptRoot -Destination $scripts -Recurse
    Write-CaelestiaJsonAtomic (Join-Path $scripts 'update-trust.json') @{ status = 'unconfigured'; rootKeys = @() }
    [IO.Directory]::CreateDirectory($prefix) | Out-Null
    Write-CaelestiaJsonAtomic (Join-Path $prefix 'install.json') @{
        product = 'caelestia-windows'; version = 1; prefix = $prefix; profile = (Join-Path $root 'profile')
        installId = 'nexus-fixture'; sourceRevision = 'fixture'; releaseId = '0.2.0-local'
    }
    $before = [IO.File]::ReadAllBytes((Join-Path $prefix 'install.json'))
    $ErrorActionPreference = 'Continue'
    $output = & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$scripts\Manage-Caelestia.ps1" `
        -Prefix $prefix -Command Update -Wait -ExpectedCurrent 'fixture' -ExpectedBuild '0.2.0-dev.1.1.1' -Channel development 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($exitCode -ne 0 -and "$output" -match 'Updates are not configured') 'Production worker did not fail closed.'
    Assert ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $prefix 'install.json')))) 'Refused worker changed selector.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'profile'))) 'Refused worker created profile/journal.'
    $check = & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$scripts\Manage-Caelestia.ps1" `
        -Prefix $prefix -Command CheckUpdate -Channel development | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and $check.state -ceq 'not-configured') 'Production CheckUpdate contract.'
    $global:LASTEXITCODE = 0
    Write-Output "PASS Nexus bounded primitives and fail-closed worker: $count assertions. No network/install/desktop acceptance claimed."
} finally {
    Assert-CaelestiaUpdatePath $root
    if ((Split-Path -Parent $root) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path -Leaf $root) -notlike 'caelestia-nexus-test-*') { throw 'Unsafe fixture cleanup.' }
    Assert-CaelestiaNoReparsePoints $root
    Remove-Item -LiteralPath $root -Recurse -Force
}
