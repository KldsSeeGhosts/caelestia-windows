[CmdletBinding()]
param(
    [string]$Base,
    [string]$Head = 'HEAD',
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    [string]$RepoRoot
)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path }
$mode = 'full'
. "$PSScriptRoot\..\capture\Source.ps1"
# Unknown/new events, first pushes and unavailable bases must fail closed to
# a full build. There are no broad path exclusions hiding runtime changes.
if ($EventName -eq 'pull_request' -and $Base -match '^[a-f0-9]{40}$' -and $Base -ne ('0' * 40)) {
    $ErrorActionPreference = 'Continue'
    $null = & git -C $RepoRoot cat-file -e "${Base}^{commit}" 2>$null
    $basePresent = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if ($basePresent) {
        # Git quotes control characters; quoted/ambiguous names fail closed.
        $raw = & git -C $RepoRoot -c core.quotepath=false diff --name-only --no-renames $Base $Head --
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine changed source paths.' }
        $files = @($raw)
        $modes = @(& git -C $RepoRoot diff --raw --no-renames $Base $Head --)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine changed input modes.' }
        $gitlinks = @($modes | Where-Object { $_ -match '^:(160000 [0-9]{6}|[0-9]{6} 160000) ' })
        $docs = '^(README\.md|CONTRIBUTING\.md|windows/(README\.md|NATIVE-BUILD\.md|ROADMAP\.md|docs/.+\.md))$'
        if ($files.Count -gt 0 -and -not $gitlinks.Count) {
            $nonDocs = @($files | Where-Object { $_ -cnotmatch $docs })
            if (-not $nonDocs.Count) { $mode = 'none' }
            elseif (-not @($nonDocs | Where-Object { Test-CaelestiaCiNativeInput $_ }).Count) { $mode = 'reuse' }
        }
    }
}
if ($env:GITHUB_OUTPUT) { "native=$mode" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8 }
Write-Output "Native validation mode: $mode"
