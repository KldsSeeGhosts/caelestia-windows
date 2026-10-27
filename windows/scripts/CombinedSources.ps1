# Shared merge for the combined prototype staging map. Every feature owns one
# fragment under sources.d, so parallel features never edit the same file. The
# merge order is the ordinal sort of the fragment file names. An ambiguous map
# (one destination staged twice, or one source mapped to two destinations) is
# rejected instead of silently letting the last entry win.
$ErrorActionPreference = 'Stop'

function Get-CombinedSourcesManifest([string]$CombinedPrototypeRoot) {
    if (-not $CombinedPrototypeRoot) { throw 'A combined prototype root is required.' }
    $fragmentDirectory = Join-Path $CombinedPrototypeRoot 'sources.d'
    if (-not (Test-Path -LiteralPath $fragmentDirectory -PathType Container)) {
        throw "Missing combined staging fragments: $fragmentDirectory"
    }
    $names = [string[]]@(Get-ChildItem -LiteralPath $fragmentDirectory -Filter '*.json' -File |
        ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    if ($names.Count -eq 0) { throw "No combined staging fragments in $fragmentDirectory" }

    $manifest = [ordered]@{}
    $destinationOwner = @{}
    $sources = @{}
    foreach ($name in $names) {
        $path = Join-Path $fragmentDirectory $name
        $fragment = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $properties = @($fragment.PSObject.Properties)
        if ($properties.Count -eq 0) { throw "Combined staging fragment has no entries: $path" }
        foreach ($property in $properties) {
            $source = $property.Name
            $destination = [string]$property.Value
            if ([string]::IsNullOrWhiteSpace($destination)) {
                throw "Combined staging fragment maps '$source' to an empty destination: $name"
            }
            if ($destinationOwner.ContainsKey($destination)) {
                $owner = $destinationOwner[$destination]
                if ($owner -eq $name) {
                    throw "Duplicate combined staging destination '$destination' twice in $name."
                }
                throw "Duplicate combined staging destination '$destination' in $owner and $name."
            }
            if ($sources.ContainsKey($source) -and $sources[$source].destination -ne $destination) {
                $known = $sources[$source]
                throw "Duplicate combined staging source '$source' maps to '$($known.destination)' in $($known.fragment) and '$destination' in $name."
            }
            $destinationOwner[$destination] = $name
            $sources[$source] = [pscustomobject]@{ destination = $destination; fragment = $name }
            $manifest.Add($source, $destination)
        }
    }
    return [pscustomobject]$manifest
}
