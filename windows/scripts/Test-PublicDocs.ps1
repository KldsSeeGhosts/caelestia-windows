#requires -Version 5.1
<#
.SYNOPSIS
    Checks the shipped documentation for private references and broken links.

.DESCRIPTION
    Scans the public documentation set only: the root README and CONTRIBUTING,
    and windows/**/*.md excluding windows/validation, windows/audits,
    windows/.local and windows/deps (vendored third-party documentation).

    Fails on:
      - links to private trackers or private hosts;
      - private tracker identifiers and private branch names;
      - personal absolute paths;
      - agent assignments in shipped instructions;
      - relative links that do not resolve inside this repository, and URLs
        that are not well-formed http(s) URLs.

    It does not contact the network and does not change anything.

.PARAMETER RepoRoot
    Repository root. Defaults to the root this script lives under.

.PARAMETER Json
    Emit a single JSON result instead of the text report.

.EXAMPLE
    powershell -NoProfile -File windows/scripts/Test-PublicDocs.ps1

.EXAMPLE
    powershell -NoProfile -File windows/scripts/Test-PublicDocs.ps1 -Json
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$repoPrefix = $RepoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

$privateHosts = @(
    'linear.app',
    'trello.com',
    'notion.so',
    'slack.com',
    'teams.microsoft.com',
    'sharepoint.com',
    'ts.net'
)

# The word "agent" alone is legitimate (cpa-agents.json); assignments are not.
$privateRules = @(
    @{ Kind = 'private-tracker'; Pattern = '\bERM-[0-9]+\b'; Message = 'private tracker identifier' },
    @{ Kind = 'private-tracker'; Pattern = '(?i)\bLinear\b'; Message = 'private tracker reference' },
    @{ Kind = 'private-branch'; Pattern = '(?i)(?<![\w.-])t3/'; Message = 'private branch reference' },
    @{ Kind = 'personal-path'; Pattern = '(?i)\b[A-Z]:[\\/]+Users[\\/]+'; Message = 'personal Windows profile path' },
    @{ Kind = 'agent-assignment'; Pattern = '(?i)\b(QA|coding|implementation|desktop|review)\s+agents?\b'; Message = 'agent assignment' }
)

function Get-ShippedDocs {
    param([string]$Root)

    $docs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('README.md', 'CONTRIBUTING.md')) {
        $path = Join-Path $Root $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $docs.Add($path) }
    }

    $windows = Join-Path $Root 'windows'
    if (Test-Path -LiteralPath $windows -PathType Container) {
        Get-ChildItem -LiteralPath $windows -Recurse -File -Filter '*.md' |
            Where-Object {
                $_.FullName -notmatch '[\\/](validation|audits|\.local|deps)[\\/]'
            } |
            ForEach-Object { $docs.Add($_.FullName) }
    }

    $docs | Sort-Object -Unique
}

function Get-RepoRelativePath {
    param([string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($repoPrefix.Length).Replace('\', '/')
    }
    return $full.Replace('\', '/')
}

function Resolve-DocTarget {
    param(
        [string]$File,
        [string]$Target
    )

    $value = $Target.Trim()
    if ($value.StartsWith('<') -and $value.EndsWith('>')) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    # Drop an optional link title: path "title".
    $titleIndex = $value.IndexOf(' "')
    if ($titleIndex -ge 0) { $value = $value.Substring(0, $titleIndex) }

    if ($value.Length -eq 0 -or $value.StartsWith('#')) { return $null }
    if ($value -match '^(?i)(https?):') { return @{ Kind = 'url'; Value = $value } }
    if ($value -match '^[A-Za-z][A-Za-z0-9+.-]*:') { return @{ Kind = 'bad-scheme'; Value = $value } }

    $pathPart = $value
    $queryIndex = $pathPart.IndexOfAny([char[]]@('?', '#'))
    if ($queryIndex -ge 0) { $pathPart = $pathPart.Substring(0, $queryIndex) }
    try { $pathPart = [Uri]::UnescapeDataString($pathPart) } catch { }

    if ($pathPart.Length -eq 0) { return $null }

    if ($pathPart.StartsWith('/')) {
        $candidate = Join-Path $RepoRoot $pathPart.TrimStart('/')
    }
    else {
        $candidate = Join-Path (Split-Path -Parent $File) $pathPart
    }

    return @{ Kind = 'file'; Value = $candidate; Display = $value }
}

function Test-PublicUrl {
    param([string]$Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        return 'not a well-formed absolute URL'
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        return "unsupported URL scheme '$($uri.Scheme)'"
    }
    $hostName = $uri.Host.ToLowerInvariant()
    foreach ($blocked in $privateHosts) {
        if ($hostName -eq $blocked -or $hostName.EndsWith('.' + $blocked, [StringComparison]::Ordinal)) {
            return "link to private host '$hostName'"
        }
    }
    return $null
}

$findings = New-Object 'System.Collections.Generic.List[object]'
$docs = @(Get-ShippedDocs -Root $RepoRoot)
if (@($docs).Count -eq 0) {
    $findings.Add([pscustomobject]@{
        File = '.'
        Line = 0
        Kind = 'configuration'
        Message = 'No shipped documentation was found.'
    })
}

foreach ($file in $docs) {
    $relative = Get-RepoRelativePath -Path $file
    $lines = @(Get-Content -LiteralPath $file -Encoding UTF8)
    $inFence = $false
    $fenceMarker = $null

    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $lineNumber = $i + 1
        $line = $lines[$i]

        foreach ($rule in $privateRules) {
            if ($line -match $rule.Pattern) {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Kind = $rule.Kind
                    Message = "$($rule.Message): $($Matches[0])"
                })
            }
        }

        $trimmed = $line.TrimStart()
        if ($trimmed -match '^(```|~~~)') {
            $marker = $Matches[1]
            if (-not $inFence) {
                $inFence = $true
                $fenceMarker = $marker
            }
            elseif ($marker -eq $fenceMarker) {
                $inFence = $false
                $fenceMarker = $null
            }
            continue
        }
        $targets = New-Object 'System.Collections.Generic.List[string]'

        # Code blocks are not links, but a private host in an example still leaks.
        if ($inFence) {
            foreach ($match in [regex]::Matches($line, '(?i)https?://[^\s<>"''`)]+')) {
                $problem = Test-PublicUrl -Value $match.Value
                # Examples may hold placeholder URLs; only private hosts fail here.
                if ($problem -like 'link to private host*') {
                    $findings.Add([pscustomobject]@{
                        File = $relative
                        Line = $lineNumber
                        Kind = 'link'
                        Message = "$problem ($($match.Value))"
                    })
                }
            }
            continue
        }

        # Inline links and images: [text](target) and ![alt](target).
        foreach ($match in [regex]::Matches($line, '!?\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+["''][^"'']*["''])?\s*\)')) {
            $targets.Add($match.Groups[1].Value)
        }

        # Reference-style definitions: [label]: target
        foreach ($match in [regex]::Matches($line, '^\s*\[[^\]]+\]:\s*(<[^>]+>|\S+)')) {
            $targets.Add($match.Groups[1].Value)
        }

        # Bare URLs in prose are checked for private hosts and validity too.
        foreach ($match in [regex]::Matches($line, '(?i)https?://[^\s<>"'')]+')) {
            $targets.Add($match.Value)
        }

        foreach ($target in $targets) {
            $resolved = Resolve-DocTarget -File $file -Target $target
            if ($null -eq $resolved) { continue }

            if ($resolved.Kind -eq 'url') {
                $problem = Test-PublicUrl -Value $resolved.Value
                if ($problem) {
                    $findings.Add([pscustomobject]@{
                        File = $relative
                        Line = $lineNumber
                        Kind = 'link'
                        Message = "$problem ($($resolved.Value))"
                    })
                }
                continue
            }

            if ($resolved.Kind -eq 'bad-scheme') {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Kind = 'link'
                    Message = "non-public link scheme ($($resolved.Value))"
                })
                continue
            }

            $candidate = [IO.Path]::GetFullPath($resolved.Value)
            if (-not $candidate.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Kind = 'link'
                    Message = "link escapes the repository ($($resolved.Display))"
                })
                continue
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                $findings.Add([pscustomobject]@{
                    File = $relative
                    Line = $lineNumber
                    Kind = 'link'
                    Message = "link does not resolve inside the repository ($($resolved.Display))"
                })
            }
        }
    }
}

$result = [pscustomobject]@{
    Check = 'Test-PublicDocs'
    Passed = ($findings.Count -eq 0)
    Files = @($docs).Count
    Findings = $findings.Count
    Details = $findings.ToArray()
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5
    if ($result.Passed) { exit 0 } else { exit 1 }
}

Write-Host "Test-PublicDocs: scanning $(@($docs).Count) shipped documentation files"
if ($result.Passed) {
    Write-Host 'Test-PublicDocs: PASS - no private references or broken links.'
    exit 0
}

foreach ($finding in $findings) {
    Write-Host ("FAIL {0}:{1}: [{2}] {3}" -f $finding.File, $finding.Line, $finding.Kind, $finding.Message)
}
Write-Host ("Test-PublicDocs: FAIL - {0} finding(s) in {1} file(s)." -f $findings.Count, @($docs).Count)
exit 1
