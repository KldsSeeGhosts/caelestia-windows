# Redaction for agent-facing records: candidate manifests, benchmark metadata,
# verdicts and baselines. A record is not a machine dump. Serialise it with
# known roots and personal paths replaced by stable placeholders, and verify the
# result never carries a home path or the account name.
# This text-only scrubber cannot redact minidumps. The backend keeps local
# process-memory dumps under %LOCALAPPDATA%\quickshell\cache\crashes, outside
# the owned Caelestia profile. Never pass binary dumps through these functions
# or treat a scrubbed log as proof that an associated dump is safe to share.
#
# Dot-source this file, then call Initialize-CaelestiaPrivacy with the caller's
# own roots, for example @{ from = $repoRoot; to = '<repo>' }.

# A path can be spelled long or 8.3-short, with either separator.
function Get-ShortPath([string]$Path) {
    try {
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Container)) {
            return (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Path).ShortPath
        }
    } catch {}
    return $null
}
function Get-PathSpellings([string]$Path) {
    $spellings = foreach ($form in @($Path, (Get-ShortPath $Path))) {
        if ($form) { $form.TrimEnd('\'); $form.TrimEnd('\').Replace('\', '/') }
    }
    return @($spellings | Select-Object -Unique)
}

function Initialize-CaelestiaPrivacy([hashtable[]]$Roots = @()) {
    $script:homeSpellings = @(Get-PathSpellings $env:USERPROFILE)
    # The account name and the profile folder name can differ, and the folder can
    # also appear in its 8.3 form, so each one is redacted as a name.
    $nameTokens = @(
        [string]$env:USERNAME
        if ($env:USERPROFILE) { Split-Path -Leaf $env:USERPROFILE }
        $shortHome = Get-ShortPath $env:USERPROFILE
        if ($shortHome) { Split-Path -Leaf $shortHome }
    ) | Where-Object { $_ } | Select-Object -Unique
    $script:userNamePattern = if ($nameTokens) {
        '(?<![A-Za-z0-9._~-])(?:' + (($nameTokens | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![A-Za-z0-9._~-])'
    } else { $null }
    # Any folder directly under the profiles root (C:\Users) is someone's home,
    # whatever its spelling: renamed, 8.3-short, either separator or doubled.
    $script:profilePattern = if ($env:USERPROFILE) {
        $profilesRoot = Split-Path -Parent $env:USERPROFILE
        '(?i)' + ((($profilesRoot -split '[\\/]+') | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]+') + '[\\/]+[^\\/"''\s<>|]+'
    } else { $null }
    $script:pathReplacements = @(@($Roots) + @(
        @{ from = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\'); to = '<temp>' },
        @{ from = $env:USERPROFILE; to = '%USERPROFILE%' },
        @{ from = $HOME; to = '%USERPROFILE%' },
        @{ from = $env:LOCALAPPDATA; to = '%LOCALAPPDATA%' },
        @{ from = $env:APPDATA; to = '%APPDATA%' },
        @{ from = $env:TEMP; to = '<temp>' }
    ) | Where-Object { $_.from } | ForEach-Object {
        $to = $_.to
        foreach ($spelling in Get-PathSpellings $_.from) { @{ from = $spelling; to = $to } }
    } | Sort-Object { $_.from.Length } -Descending)
}

function Protect-ManifestString([string]$Text) {
    if (-not $Text) { return $Text }
    foreach ($replacement in $pathReplacements) {
        if ($Text.IndexOf($replacement.from, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            # Only whole path segments: C:\Users\Ann must not eat C:\Users\ANNE~1.
            $Text = [regex]::Replace($Text, [regex]::Escape($replacement.from) + '(?![^\\/"''\s;,])', $replacement.to.Replace('$', '$$'), 'IgnoreCase')
        }
    }
    if ($profilePattern) { $Text = [regex]::Replace($Text, $profilePattern, '%USERPROFILE%') }
    if ($userNamePattern) { $Text = [regex]::Replace($Text, $userNamePattern, '%USERNAME%', 'IgnoreCase') }
    return $Text
}

function ConvertTo-SafeManifestValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-ManifestString $Value }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = ConvertTo-SafeManifestValue $property.Value
        }
        return $copy
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($Value.Keys)) { $copy[$key] = ConvertTo-SafeManifestValue $Value[$key] }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-SafeManifestValue $_ })
    }
    return $Value
}

function Get-ManifestPrivacyReport([string]$Path) {
    $report = [pscustomobject]@{ exists = $false; homeHits = 0; userHits = 0; total = 0 }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $report }
    $json = Get-Content -LiteralPath $Path -Raw
    # JSON escapes backslashes and may escape forward slashes; check the
    # unescaped text against every spelling of the home path.
    $plain = ($json -replace '\\\\', '\') -replace '\\/', '/'
    foreach ($spelling in $homeSpellings) {
        $report.homeHits += [regex]::Matches($plain, [regex]::Escape($spelling), 'IgnoreCase').Count
    }
    if ($profilePattern) { $report.homeHits += [regex]::Matches($plain, $profilePattern).Count }
    if ($userNamePattern) {
        $report.userHits = [regex]::Matches($plain, $userNamePattern, 'IgnoreCase').Count
    }
    $report.total = $report.homeHits + $report.userHits
    $report.exists = $true
    return $report
}
