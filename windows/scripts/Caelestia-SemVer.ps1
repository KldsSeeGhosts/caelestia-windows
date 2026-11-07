#requires -Version 5.1
# SemVer numbers stay strings: SemVer does not impose an integer-size limit.
function ConvertTo-CaelestiaSemVer([string]$Version) {
    $pattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    $match = [regex]::Match($Version, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { throw 'Invalid SemVer 2.0.0 version.' }
    $pre = $match.Groups[4].Value
    foreach ($part in $pre.Split('.')) {
        if ($part -match '^[0-9]+$' -and $part.Length -gt 1 -and $part[0] -eq '0') {
            throw 'Numeric SemVer prerelease identifiers cannot have leading zeros.'
        }
    }
    return [pscustomobject]@{
        Major = $match.Groups[1].Value; Minor = $match.Groups[2].Value; Patch = $match.Groups[3].Value
        Core = $match.Groups[1].Value + '.' + $match.Groups[2].Value + '.' + $match.Groups[3].Value
        Prerelease = $pre; Build = $match.Groups[5].Value; Version = $Version
    }
}

function Compare-CaelestiaDecimal([string]$Left, [string]$Right) {
    if ($Left -cnotmatch '^(0|[1-9][0-9]*)$' -or $Right -cnotmatch '^(0|[1-9][0-9]*)$') { throw 'Invalid unsigned decimal.' }
    if ($Left.Length -ne $Right.Length) { return [Math]::Sign($Left.Length - $Right.Length) }
    return [Math]::Sign([string]::CompareOrdinal($Left, $Right))
}

function Compare-CaelestiaSemVer([string]$Left, [string]$Right) {
    $a = ConvertTo-CaelestiaSemVer $Left
    $b = ConvertTo-CaelestiaSemVer $Right
    foreach ($field in @('Major', 'Minor', 'Patch')) {
        $result = Compare-CaelestiaDecimal $a.$field $b.$field
        if ($result) { return $result }
    }
    if (-not $a.Prerelease -and -not $b.Prerelease) { return 0 }
    if (-not $a.Prerelease) { return 1 }
    if (-not $b.Prerelease) { return -1 }
    $ap = $a.Prerelease.Split('.'); $bp = $b.Prerelease.Split('.')
    for ($i = 0; $i -lt [Math]::Min($ap.Count, $bp.Count); $i++) {
        $an = $ap[$i] -cmatch '^[0-9]+$'; $bn = $bp[$i] -cmatch '^[0-9]+$'
        if ($an -and $bn) { $result = Compare-CaelestiaDecimal $ap[$i] $bp[$i] }
        elseif ($an -ne $bn) { $result = if ($an) { -1 } else { 1 } }
        else { $result = [Math]::Sign([string]::CompareOrdinal($ap[$i], $bp[$i])) }
        if ($result) { return $result }
    }
    return [Math]::Sign($ap.Count - $bp.Count)
}

function Test-CaelestiaDevVersion([string]$Version) {
    # Restricted *publication* grammar, separate from the general SemVer parser.
    return $Version -cmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dev\.[1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*$'
}

function Read-CaelestiaVersion([string]$Path) {
    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($value.schema -ne 1 -or $value.version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        [string]$value.developmentEpoch -cnotmatch '^[1-9][0-9]*$' -or $value.profileSchema -ne 1) {
        throw 'Invalid authoritative version file.'
    }
    $parsed = ConvertTo-CaelestiaSemVer $value.version
    foreach ($part in @($parsed.Major, $parsed.Minor, $parsed.Patch)) {
        if ((Compare-CaelestiaDecimal $part '65535') -gt 0) { throw 'Native version components must fit Windows VERSIONINFO.' }
    }
    return $value
}
