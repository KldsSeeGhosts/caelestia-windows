#requires -Version 5.1
[CmdletBinding()]
param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\Caelestia-Update.ps1"
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Test-UpdateTrust.ps1", [ref]$tokens, [ref]$errors)
foreach ($name in @('New-Key', 'JsonBytes', 'Sign')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $function) { throw 'Ephemeral primitive fixture is missing.' }
    . ([scriptblock]::Create($function.Extent.Text))
}
# Reuse the already-permitted ephemeral primitives. No owner key-tool command,
# persistent provider key, private key file or production trust path is used.
$rootKey = New-Key; $devKey = New-Key; $promotionKey = New-Key; $secondDevKey = New-Key
try {
    $future = [DateTime]::UtcNow.AddDays(90).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $trust = @{
        schema = 'caelestia-update-trust'; version = 1; rootVersion = 1; status = 'configured'
        repository = 'KldsSeeGhosts/caelestia-windows'
        metadataBase = 'https://raw.githubusercontent.com/KldsSeeGhosts/caelestia-windows/nexus-channels/v1/'
        assetPrefix = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/'
        redirectHosts = @('objects.githubusercontent.com', 'release-assets.githubusercontent.com')
        rootKeys = @($rootKey.Public); rootThreshold = 1; requireAuthenticode = $false
    }
    $keys = @{ type = 'caelestia-update-keys'; schema = 1; repository = $trust.repository; version = 1
        expires = $future; threshold = 1
        keys = @(@{ public = $devKey.Public; channels = @('development'); notAfter = $future },
            @{ public = $promotionKey.Public; channels = @('preview', 'stable'); notAfter = $future }) }
    $keys2 = $keys.Clone(); $keys2.version = 2
    $revoked = $keys2.Clone(); $revoked.keys = @($keys.keys[1])
    $expired = $keys.Clone(); $expired.expires = [DateTime]::UtcNow.AddDays(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $threshold = $keys2.Clone(); $threshold.threshold = 2
    $threshold.keys = @($keys.keys[0], $keys.keys[1], @{ public = $secondDevKey.Public; channels = @('development'); notAfter = $future })
    $material = @{
        trust = $trust
        dev = [Convert]::ToBase64String($devKey.Private)
        promotion = [Convert]::ToBase64String($promotionKey.Private)
        secondDev = [Convert]::ToBase64String($secondDevKey.Private)
        keys = [Convert]::ToBase64String((Sign $keys 'keys' $rootKey))
        keys2 = [Convert]::ToBase64String((Sign $keys2 'keys' $rootKey))
        revoked = [Convert]::ToBase64String((Sign $revoked 'keys' $rootKey))
        expiredKeys = [Convert]::ToBase64String((Sign $expired 'keys' $rootKey))
        threshold = [Convert]::ToBase64String((Sign $threshold 'keys' $rootKey))
        historical = @{}
    }
    foreach ($channel in @('development', 'preview', 'stable')) {
        $build = '1.0.0-dev.1.5.1'
        $display = if ($channel -eq 'development') { $build } elseif ($channel -eq 'preview') { '1.0.0-preview.1' } else { '1.0.0' }
        $zipRoot = "caelestia-windows-$build-windows-x64"
        $payload = @{ type = 'caelestia-update-channel'; schema = 1; repository = $trust.repository; channel = $channel
            sequence = 4; keysVersion = 1
            issuedAt = [DateTime]::UtcNow.AddDays(-15).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            expires = [DateTime]::UtcNow.AddDays(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            release = @{
                displayVersion = $display; buildVersion = $build; releaseId = $build; tag = "v$display"
                sourceRevision = 'a' * 40; backendRevision = 'b' * 40; manifestSha256 = 'c' * 64
                profileSchema = 1; minimumUpdaterSchema = 1
                notesUrl = "https://github.com/$($trust.repository)/releases/tag/v$display"
                bundle = @{ name = "$zipRoot.zip"; root = $zipRoot; size = 12; entries = 1; unpackedSize = 20; sha256 = 'd' * 64
                    url = $trust.assetPrefix + "v$display/$zipRoot.zip" }
                provenance = @{ runId = '5'; runAttempt = '1'; pairResultSha256 = 'e' * 64; candidateReceiptSha256 = 'f' * 64 }
            } }
        $key = if ($channel -eq 'development') { $devKey } else { $promotionKey }
        $material.historical[$channel] = [Convert]::ToBase64String((Sign $payload 'channel' $key))
    }
    $env:NEXUS_TEST_KEY_MATERIAL = $material | ConvertTo-Json -Depth 20 -Compress
    $env:PYTHONDONTWRITEBYTECODE = '1'
    & $Python -I -B "$PSScriptRoot\..\tests\nexus_pipeline\test_nexus_pipeline.py" -v
    if ($LASTEXITCODE -ne 0) { throw 'Nexus publication/candidate behavioral controls failed.' }
} finally {
    $env:NEXUS_TEST_KEY_MATERIAL = $null
    foreach ($key in @($rootKey, $devKey, $promotionKey, $secondDevKey)) { [Array]::Clear($key.Private, 0, $key.Private.Length) }
    $material = $null
}
