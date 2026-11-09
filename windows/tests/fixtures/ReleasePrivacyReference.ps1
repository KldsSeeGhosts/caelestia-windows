# Previous scanner policy, retained only as a differential-test reference.
function Get-ReferenceReleaseFilePrivacy([byte[]]$Bytes, [string]$Extension, [string[]]$PrivateRoots) {
    $texts = @([Text.Encoding]::UTF8.GetString($Bytes), [Text.Encoding]::Unicode.GetString($Bytes))
    if ($Bytes.Length -gt 1) { $texts += [Text.Encoding]::Unicode.GetString($Bytes, 1, $Bytes.Length - 1) }
    $sensitive = $false
    $genericPath = $false
    $keyWhitespace = '(?:\s|\\+[rn])*'
    $keyMaterial = '(?i)-----BEGIN (?:(?:RSA|EC|DSA|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----' +
        $keyWhitespace + '(?:(?:[A-Za-z0-9+/=]' + $keyWhitespace + '){32,}|Proc-Type:' + $keyWhitespace + '4,ENCRYPTED)'
    foreach ($text in $texts) {
        if ($text -match $keyMaterial -or $text -match '(?i)(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}') {
            $sensitive = $true
        }
        if ($text -match '(?i)[A-Z]:[\\/]+Users[\\/]|/(Users|home)/[^/\s]+/|[A-Z]:[\\/][^\x00\r\n]*\.pdb\b') {
            $genericPath = $true
        }
        if ($Extension -in @('.dll', '.exe')) {
            foreach ($candidate in [regex]::Matches($text, '(?i)(?<![A-Za-z0-9])[A-Z]:[\\/][^\x00\r\n]{2,}')) {
                if ($candidate.Value -notmatch '[\p{C}\ufffd]' -or
                    $candidate.Value -match '^(?i)[A-Z]:[\\/](?:[\p{L}\p{N}_. -]+[\\/]|[^<>:"|?*\x00-\x1f]*\.[A-Za-z0-9]{1,8}(?:$|[^\w]))') {
                    $genericPath = $true
                }
            }
        }
        foreach ($privateRoot in $PrivateRoots) {
            foreach ($spelling in @($privateRoot, $privateRoot.Replace('\', '/'), $privateRoot.Replace('\', '\\'))) {
                if ($text.IndexOf($spelling, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $sensitive = $true }
            }
        }
    }
    return [pscustomobject]@{ Sensitive = $sensitive; GenericPath = $genericPath }
}
