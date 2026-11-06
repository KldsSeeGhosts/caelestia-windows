param()

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$matrixPath = Join-Path $PSScriptRoot "provider-support.json"
$docPath = Join-Path $PSScriptRoot "..\docs\PROVIDER-SUPPORT.md"
$stagingPath = Join-Path $repoRoot "windows\shell\sources.json"
$lockPath = Join-Path $repoRoot "windows\sources.lock.json"

function Get-Field {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Copy-JsonObject {
    param([Parameter(Mandatory = $true)] $Value)
    return (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 100))
}

function Test-ProviderSupportMatrix {
    param(
        [Parameter(Mandatory = $true)] $Matrix,
        [Parameter(Mandatory = $true)] $StagingMap,
        [Parameter(Mandatory = $true)] $SourceLock,
        [Parameter(Mandatory = $true)] [string] $Document,
        [Parameter(Mandatory = $true)] [string] $Root
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $expectedCategories = @("supported", "unsupported", "denied", "unavailable", "transient", "failed", "empty")
    $expectedFields = @("ready", "requested", "accepted", "completed")
    $hardwareOwners = @{ brightness = 13; network = 14; keyboard = 15 }
    $expectedProviderIds = @(
        "shell", "tiling", "audio", "battery", "bluetooth", "brightness", "network",
        "media", "notifications", "desktop", "capture", "idleInhibit", "keyboard", "tray", "wallpaper"
    )
    $actualCategories = @($Matrix.supportContract.categories)
    $actualFields = @($Matrix.supportContract.nullableBooleanFields)
    $actualProviderIds = @($Matrix.supportContract.supportBundleV1.providerIds)

    if ($Matrix.matrixVersion -ne 1) {
        $problems.Add("matrixVersion must be 1.")
    }
    if ((Compare-Object $expectedCategories $actualCategories).Count -ne 0) {
        $problems.Add("support category vocabulary differs from the v1 contract.")
    }
    if ((Compare-Object $expectedFields $actualFields).Count -ne 0) {
        $problems.Add("nullable operation fields differ from the v1 contract.")
    }
    if ((Compare-Object $expectedProviderIds $actualProviderIds).Count -ne 0) {
        $problems.Add("support-bundle provider IDs differ from the v1 contract.")
    }
    if ($Matrix.supportContract.supportBundleV1.identityTrust -ne "declared-unverified") {
        $problems.Add("support-bundle identity trust must remain declared-unverified.")
    }
    if ($Matrix.supportContract.supportBundleV1.providerObservation -ne "Caller-supplied offline snapshot only; no live provider query is implied.") {
        $problems.Add("support-bundle provider observations must remain caller-supplied and offline.")
    }
    if ($Matrix.supportContract.supportBundleV1.clipboardProviderId -ne $null) {
        $problems.Add("clipboard must not be assigned an unimplemented support-bundle v1 provider ID.")
    }

    $pins = @(
        @{ Label = "backend"; Matrix = $Matrix.baseline.backendRevision; Lock = $SourceLock.quickshell.revision },
        @{ Label = "glazier"; Matrix = $Matrix.baseline.glazierRevision; Lock = $SourceLock.glazier.revision },
        @{ Label = "m3shapes"; Matrix = $Matrix.baseline.m3shapesRevision; Lock = $SourceLock.m3shapes.revision }
    )
    foreach ($pin in $pins) {
        if ($pin.Matrix -ne $pin.Lock) {
            $problems.Add("pin mismatch: $($pin.Label) matrix $($pin.Matrix) != lock $($pin.Lock).")
        }
    }
    foreach ($repoName in @("shell", "backend", "glazier", "m3shapes")) {
        $repository = Get-Field $Matrix.sourceRepositories $repoName
        $revisionField = if ($repoName -eq "shell") { "shellRevision" } elseif ($repoName -eq "backend") { "backendRevision" } else { "${repoName}Revision" }
        $baselineRevision = Get-Field $Matrix.baseline $revisionField
        if ($null -eq $repository -or $repository.revision -ne $baselineRevision) {
            $problems.Add("source repository revision differs from baseline: $repoName.")
        }
        if ($null -eq $repository -or [string]::IsNullOrWhiteSpace($repository.url)) {
            $problems.Add("source repository URL is missing: $repoName.")
        }
    }

    $seenCapabilities = @{}
    foreach ($capability in @($Matrix.capabilities)) {
        $id = [string]$capability.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $problems.Add("capability id is missing.")
            continue
        }
        if ($seenCapabilities.ContainsKey($id)) {
            $problems.Add("duplicate capability id: $id.")
        }
        $seenCapabilities[$id] = $true

        if ($null -ne $capability.bundleProviderId -and $capability.bundleProviderId -notin $actualProviderIds) {
            $problems.Add("unknown bundle provider ID '$($capability.bundleProviderId)' on $id.")
        }
        if (@($capability.operations).Count -eq 0 -or @($capability.degradedExamples).Count -eq 0) {
            $problems.Add("operations and degraded examples are required for $id.")
        }
        foreach ($example in @($capability.degradedExamples)) {
            if ($example.category -notin $expectedCategories) {
                $problems.Add("invalid degraded category '$($example.category)' on $id.")
            }
        }
        if (@($capability.staging).Count -eq 0) {
            $problems.Add("staging trace is missing for $id.")
        }
        foreach ($stage in @($capability.staging)) {
            $mapping = $StagingMap.PSObject.Properties[[string]$stage.source]
            if ($null -eq $mapping -or $mapping.Value -ne $stage.destination) {
                $problems.Add("staging mapping mismatch: $($stage.source) => $($stage.destination).")
            }
        }

        if (@($capability.sourceLinks).Count -lt 2) {
            $problems.Add("at least two pinned source links are required for $id.")
        }
        foreach ($link in @($capability.sourceLinks)) {
            $repository = Get-Field $Matrix.sourceRepositories ([string]$link.repository)
            if ($null -eq $repository) {
                $problems.Add("unknown source-link repository '$($link.repository)' on $id.")
                continue
            }
            $path = [string]$link.path
            if ([string]::IsNullOrWhiteSpace($path) -or $path.StartsWith("/") -or $path.Contains("..")) {
                $problems.Add("invalid source-link path '$path' on $id.")
                continue
            }
            $expectedUrl = "$($repository.url)/blob/$($repository.revision)/$path"
            if ([string]$link.url -cne $expectedUrl) {
                $problems.Add("source URL mismatch: $($link.url).")
                continue
            }
            $repoRoot = Join-Path $Root ([string]$repository.localRoot)
            $linkedFile = Join-Path $repoRoot ($path -replace "/", "\")
            if (-not (Test-Path -LiteralPath $linkedFile -PathType Leaf)) {
                $problems.Add("source file not present at pinned checkout path: $($link.repository)/$path.")
            }
        }
        foreach ($owner in @($capability.acceptanceOwners)) {
            if ([string]$owner -notmatch "^https://github\.com/[^/]+/[^/]+/issues/[0-9]+$") {
                $problems.Add("acceptance owner must be a public GitHub issue URL on $id.")
            }
        }
        if ($hardwareOwners.ContainsKey($id)) {
            $expectedOwner = "https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues/$($hardwareOwners[$id])"
            if ($capability.acceptanceOwners -notcontains $expectedOwner -or -not $Document.Contains($expectedOwner)) {
                $problems.Add("acceptance owner mismatch: $id must use its backend hardware issue.")
            }
        }
    }

    foreach ($providerId in $actualProviderIds) {
        if (-not $seenCapabilities.ContainsKey([string]$providerId)) {
            $problems.Add("support-bundle provider has no matrix row: $providerId.")
        }
    }
    if (-not $seenCapabilities.ContainsKey("clipboard")) {
        $problems.Add("clipboard capability must be documented separately from support-bundle v1 IDs.")
    }

    if (-not $Document.Contains("## Maintaining this map")) {
        $problems.Add("documentation is missing the map/pin/public-capability maintenance checklist.")
    }
    foreach ($providerId in $actualProviderIds) {
        if (-not $Document.Contains("``$providerId``")) {
            $problems.Add("documentation is missing a support-bundle provider ID: $providerId.")
        }
    }
    if (-not $Document.Contains("| Clipboard picker |")) {
        $problems.Add("documentation must identify clipboard separately from support-bundle v1 IDs.")
    }
    if ($Document -match "ERM-\d+" -or $Document -match "linear\.app/" -or $Document -match "[A-Za-z]:\\Users\\[^\\]+") {
        $problems.Add("public provider documentation contains an internal tracker reference or personal path.")
    }
    if ($Document -match "(?i)\b(?:supports?|works\s+on|covers?)\s+(?:all|every)\s+(?:windows\s+)?(?:hardware|devices?|displays?|drivers?|builds?)\b" -or
        $Document -match "(?i)\b(?:all|every)\s+(?:windows\s+)?(?:hardware|devices?|displays?|drivers?|builds?)\s+(?:is|are)\s+(?:supported|compatible|covered)\b") {
        $problems.Add("public provider documentation must not claim universal hardware or Windows-build support.")
    }

    return $problems.ToArray()
}

$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
$stagingMap = Get-Content -LiteralPath $stagingPath -Raw | ConvertFrom-Json
$sourceLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$doc = Get-Content -LiteralPath $docPath -Raw

$errors = @(Test-ProviderSupportMatrix -Matrix $matrix -StagingMap $stagingMap -SourceLock $sourceLock -Document $doc -Root $repoRoot)
if ($errors.Count -gt 0) {
    throw ("Provider support traceability validation failed:`n - " + ($errors -join "`n - "))
}

# Negative controls mutate in-memory copies only. They demonstrate that the
# check catches a missing map destination, a changed dependency pin, and a
# source URL that no longer points at its recorded commit/path.
$missingStage = Copy-JsonObject $matrix
$missingStage.capabilities[0].staging[0].destination = "modules/session/missing.qml"
$negative = @(Test-ProviderSupportMatrix -Matrix $missingStage -StagingMap $stagingMap -SourceLock $sourceLock -Document $doc -Root $repoRoot)
if (-not ($negative | Where-Object { $_ -like "staging mapping mismatch:*" })) {
    throw "Negative control failed: a missing staging destination was not detected."
}

$wrongPin = Copy-JsonObject $sourceLock
$wrongPin.quickshell.revision = "0000000000000000000000000000000000000000"
$negative = @(Test-ProviderSupportMatrix -Matrix $matrix -StagingMap $stagingMap -SourceLock $wrongPin -Document $doc -Root $repoRoot)
if (-not ($negative | Where-Object { $_ -like "pin mismatch: backend*" })) {
    throw "Negative control failed: a dependency pin mismatch was not detected."
}

$brokenLink = Copy-JsonObject $matrix
$brokenLink.capabilities[0].sourceLinks[0].url = "https://example.invalid/broken-source"
$negative = @(Test-ProviderSupportMatrix -Matrix $brokenLink -StagingMap $stagingMap -SourceLock $sourceLock -Document $doc -Root $repoRoot)
if (-not ($negative | Where-Object { $_ -like "source URL mismatch:*" })) {
    throw "Negative control failed: a broken source link was not detected."
}

$negative = @(Test-ProviderSupportMatrix -Matrix $matrix -StagingMap $stagingMap -SourceLock $sourceLock -Document ($doc + "`nAll hardware is supported.") -Root $repoRoot)
if (-not ($negative | Where-Object { $_ -like "public provider documentation must not claim universal*" })) {
    throw "Negative control failed: a universal hardware claim was not detected."
}

$wrongOwner = Copy-JsonObject $matrix
($wrongOwner.capabilities | Where-Object id -eq 'brightness').acceptanceOwners = @('https://github.com/KldsSeeGhosts/caelestia-windows/issues/13')
$negative = @(Test-ProviderSupportMatrix -Matrix $wrongOwner -StagingMap $stagingMap -SourceLock $sourceLock -Document $doc -Root $repoRoot)
if (-not ($negative | Where-Object { $_ -like 'acceptance owner mismatch:*' })) {
    throw 'Negative control failed: an owner in the wrong repository was not detected.'
}

Write-Host ("PASS: {0} provider rows trace to staged paths, pinned source links, and dependency pins." -f $matrix.capabilities.Count)
Write-Host "PASS: missing-staging, pin-mismatch, broken-source-link, wrong-owner, and universal-claim negative controls."
Write-Host "NOTE: source trace only; provider, GUI, package, permission, and hardware behavior were not run."
