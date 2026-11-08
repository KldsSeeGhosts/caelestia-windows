#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\ci\Nexus-OwnerCommon.ps1"
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Test-UpdateTrust.ps1", [ref]$tokens, [ref]$errors)
foreach ($name in @('New-Key', 'JsonBytes', 'Sign')) {
    $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$count = 0
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message }; $script:count++ }
function Refuse([scriptblock]$Action, [string]$Name) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert $rejected "Accepted negative control: $Name"
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-owner-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$a = New-Key; $b = New-Key; $dev = New-Key; $promotion = New-Key
try {
    # Ephemeral test-only binary fixtures, deleted below. No real owner keys.
    [IO.File]::WriteAllBytes("$root\root a.pkcs8", $a.Private)
    [IO.File]::WriteAllBytes("$root\root b.pkcs8", $b.Private)
    [IO.File]::WriteAllBytes("$root\dev.pkcs8", $dev.Private)
    Write-CaelestiaJsonAtomic "$root\dev public.json" $dev.Public
    Write-CaelestiaJsonAtomic "$root\promotion.json" $promotion.Public
    $trust = Read-CaelestiaStrictJsonFile "$PSScriptRoot\..\release\update-trust.json"
    $trust.rootKeys = @($a.Public, $b.Public); $trust.rootThreshold = 2
    Write-CaelestiaJsonAtomic "$root\trust.json" $trust
    $trust = Read-CaelestiaStrictJsonFile "$root\trust.json"
    Write-CaelestiaJsonAtomic "$root\roots.json" @('root a.pkcs8', 'root b.pkcs8')
    $future = [DateTime]::UtcNow.AddDays(100).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $entries = @(@{ publicPath = 'dev public.json'; channels = @('development'); notAfter = $future },
        @{ publicPath = 'promotion.json'; channels = @('preview', 'stable') })
    Write-CaelestiaJsonAtomic "$root\delegations.json" $entries
    function Run-Keys([string]$Output, [bool]$Success = $true, [string[]]$Extra = @()) {
        $ErrorActionPreference = 'Continue'
        $text = & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$PSScriptRoot\..\ci\New-NexusKeysDocument.ps1" `
            -RootPrivateKeyListPath "$root\roots.json" -DelegatedKeysPath "$root\delegations.json" `
            -Version 7 -TrustPath "$root\trust.json" -OutputPath $Output @Extra 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Assert (($exitCode -eq 0) -eq $Success) "Owner CLI unexpected exit $exitCode, output: $text"
        foreach ($key in @($a, $b, $dev)) {
            Assert ("$text" -notlike ('*' + [Convert]::ToBase64String($key.Private) + '*')) 'Private bytes appeared in CLI output.'
        }
        return "$text"
    }
    $text = Run-Keys "$root\keys.dsse.json"
    Assert ($text -match 'Keys document version: 7' -and $text -match 'Envelope SHA-256:') 'Missing owner CLI audit output.'
    $keysBytes = [IO.File]::ReadAllBytes("$root\keys.dsse.json")
    $keys = (Read-CaelestiaDsse $keysBytes 'application/vnd.caelestia.update-keys+json' $trust.rootKeys 2).Value
    Assert-NexusOwnerKeys $keys $trust
    Assert ($keys.version -eq 7 -and $keys.keys[0].notAfter -ceq $future) 'Explicit key lifetime/version changed.'
    $singleTrust = Read-CaelestiaStrictJsonFile "$root\trust.json"
    $singleTrust.rootKeys = @($a.Public); $singleTrust.rootThreshold = 1
    Write-CaelestiaJsonAtomic "$root\single-trust.json" $singleTrust
    $singleText = & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$PSScriptRoot\..\ci\New-NexusKeysDocument.ps1" `
        -RootPrivateKeyPath "$root\root a.pkcs8" -DelegatedKeysPath "$root\delegations.json" -Version 1 `
        -TrustPath "$root\single-trust.json" -OutputPath "$root\single.dsse.json" -Expires $future
    Assert ($LASTEXITCODE -eq 0 -and "$singleText" -match 'Keys document version: 1') 'Single-root -File invocation failed.'
    # Omitted -TrustPath must resolve the shipped trust under -File. A test key
    # is not the shipped root, so it reaches and fails the signer check.
    $ErrorActionPreference = 'Continue'
    $defaultText = & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$PSScriptRoot\..\ci\New-NexusKeysDocument.ps1" `
        -RootPrivateKeyPath "$root\root a.pkcs8" -DelegatedKeysPath "$root\delegations.json" -Version 1 `
        -OutputPath "$root\default-trust.dsse.json" 2>&1
    $defaultExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Assert ($defaultExit -ne 0 -and "$defaultText" -match 'Unauthorized or duplicate root signer' -and
        -not (Test-Path "$root\default-trust.dsse.json")) "Default shipped trust path did not resolve: $defaultText"
    $hash = (Get-FileHash "$root\keys.dsse.json").Hash
    $null = Run-Keys "$root\keys.dsse.json" $false
    Assert ((Get-FileHash "$root\keys.dsse.json").Hash -ceq $hash) 'Existing output overwritten.'
    $null = Run-Keys "$PSScriptRoot\..\ci\owner-test-must-not-exist.json" $false
    Assert (-not (Test-Path "$PSScriptRoot\..\ci\owner-test-must-not-exist.json")) 'Checkout output created.'
    foreach ($roots in @(@('root a.pkcs8'), @('root a.pkcs8', 'root a.pkcs8'), @('root a.pkcs8', 'dev.pkcs8'))) {
        Write-CaelestiaJsonAtomic "$root\roots.json" $roots
        $null = Run-Keys "$root\refused.json" $false
        Assert (-not (Test-Path "$root\refused.json")) 'Invalid root signers wrote output.'
    }
    Write-CaelestiaJsonAtomic "$root\roots.json" @('root a.pkcs8', 'root b.pkcs8')
    foreach ($roles in @(@('development', 'stable'), @('preview', 'preview'), @('unknown'))) {
        $bad = @(@{ publicPath = 'dev public.json'; channels = $roles })
        Write-CaelestiaJsonAtomic "$root\delegations.json" $bad
        $null = Run-Keys "$root\refused.json" $false
    }
    Write-CaelestiaJsonAtomic "$root\delegations.json" @($entries[0], $entries[0])
    $null = Run-Keys "$root\refused.json" $false
    Write-CaelestiaJsonAtomic "$root\root-public.json" $a.Public
    Write-CaelestiaJsonAtomic "$root\delegations.json" @(@{ publicPath = 'root-public.json'; channels = @('development') })
    $null = Run-Keys "$root\refused.json" $false
    Write-CaelestiaJsonAtomic "$root\delegations.json" $entries
    $null = Run-Keys "$root\refused.json" $false @('-Expires', '2000-01-01T00:00:00Z')
    $null = Run-Keys "$root\refused.json" $false @('-Threshold', '2')
    Write-CaelestiaJsonAtomic "$root\delegations.json" (@($entries[0]) * 17)
    $null = Run-Keys "$root\refused.json" $false
    $entries[0].notAfter = '2000-01-01T00:00:00Z'
    Write-CaelestiaJsonAtomic "$root\delegations.json" $entries
    $null = Run-Keys "$root\refused.json" $false
    # The generated envelope must pass the unchanged full client verifier and
    # the publisher's own keys-document validation, not only the owner checks.
    $build = '0.2.0-dev.1.5.1'; $zipRoot = "caelestia-windows-$build-windows-x64"
    $bytes = [byte[]](1, 2, 3)
    $release = @{
        displayVersion = $build; buildVersion = $build; releaseId = $build; tag = "v$build"
        sourceRevision = 'a' * 40; backendRevision = 'b' * 40; manifestSha256 = 'c' * 64
        profileSchema = 1; minimumUpdaterSchema = 1
        notesUrl = "https://github.com/$($trust.repository)/releases/tag/v$build"
        bundle = @{ name = "$zipRoot.zip"; root = $zipRoot; size = 3; entries = 1; unpackedSize = 3
            sha256 = [Caelestia.Update.Security]::Hash($bytes); url = $trust.assetPrefix + "v$build/$zipRoot.zip" }
        provenance = @{ runId = '5'; runAttempt = '1'; pairResultSha256 = 'e' * 64; candidateReceiptSha256 = 'f' * 64 }
    }
    $channel = @{ type = 'caelestia-update-channel'; schema = 1; repository = $trust.repository; channel = 'development'
        sequence = 1; keysVersion = 7; issuedAt = [DateTime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        expires = [DateTime]::UtcNow.AddDays(10).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); release = $release }
    $pointer = Sign $channel 'channel' $dev
    $null = Test-CaelestiaMetadata $keysBytes $pointer $trust 'development' $null
    [IO.File]::WriteAllBytes("$root\document.dsse.json", $pointer)
    Write-CaelestiaJsonAtomic "$root\request.json" @{ channel = 'development' }
    & (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -File "$PSScriptRoot\..\ci\Invoke-NexusCrypto.ps1" `
        -Action ReadChannel -Directory $root -TrustPath "$root\trust.json"
    Assert ($LASTEXITCODE -eq 0) 'Publisher refused generated keys.'
    $script:requests = @()
    $fetch = {
        param($url, $hosts, $redirects, $cap, $size, $hash, $destination, $milliseconds)
        $script:requests += $url
        if ($url -ceq ($trust.metadataBase + 'keys.dsse.json')) { return ,$keysBytes }
        if ($url -ceq ($trust.metadataBase + 'development.dsse.json')) { return ,$pointer }
        Assert ($url -ceq $release.bundle.url -and $size -eq 3 -and $hash -ceq $release.bundle.sha256 -and
            $redirects -eq 3 -and $hosts -contains 'github.com') 'Bootstrap transport bounds changed.'
        [IO.File]::WriteAllBytes($destination, $bytes)
    }
    $result = Get-NexusBootstrapRelease $trust "$root\bootstrap" $fetch
    Assert ($script:requests.Count -eq 3 -and $result.Release.sourceRevision -ceq $release.sourceRevision -and
        $result.InstallCommand.Contains("-ExpectedManifestSha256 $($release.manifestSha256) -Restart")) 'Bootstrap identity/command changed.'
    Assert ((Get-FileHash $result.Bundle).Hash.ToLowerInvariant() -ceq $release.bundle.sha256) 'Bootstrap bytes changed.'
    Refuse { Get-NexusBootstrapRelease $trust "$root\bootstrap" $fetch } 'existing bootstrap directory'
    Refuse { Get-NexusBootstrapRelease $trust "$PSScriptRoot\owner-bootstrap-must-not-exist" $fetch } 'checkout bootstrap directory'
    $bytes = [byte[]](3, 2, 1)
    Refuse { Get-NexusBootstrapRelease $trust "$root\corrupt" $fetch } 'corrupt bundle'
    $bytes = [byte[]](1, 2)
    Refuse { Get-NexusBootstrapRelease $trust "$root\short" $fetch } 'short bundle'
    $pointer = Sign $channel 'channel' $promotion
    $script:requests = @()
    Refuse { Get-NexusBootstrapRelease $trust "$root\unauthorized" $fetch } 'wrong channel signer'
    Assert ($script:requests.Count -eq 2 -and -not (Test-Path "$root\unauthorized")) 'Untrusted metadata reached bundle transport.'
    $pointer = Sign $channel 'channel' $dev
    $wrongTrust = Read-CaelestiaStrictJsonFile "$PSScriptRoot\..\release\update-trust.json"
    Refuse { Get-NexusBootstrapRelease $wrongTrust "$root\wrong-root" $fetch } 'ephemeral metadata against shipped root'
    $channel.expires = '2000-01-01T00:00:00Z'
    $pointer = Sign $channel 'channel' $dev
    Refuse { Get-NexusBootstrapRelease $trust "$root\expired" $fetch } 'expired pointer'
    Write-Output "PASS Nexus owner tools: $count assertions; ephemeral keys and recording transport only."
} finally {
    foreach ($key in @($a, $b, $dev, $promotion)) { [Array]::Clear($key.Private, 0, $key.Private.Length) }
    Assert-CaelestiaUpdatePath $root
    if ((Split-Path -Parent $root) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or
        (Split-Path -Leaf $root) -notlike 'caelestia-owner-test-*') { throw 'Unsafe owner fixture cleanup.' }
    Remove-Item -LiteralPath $root -Recurse -Force
}
