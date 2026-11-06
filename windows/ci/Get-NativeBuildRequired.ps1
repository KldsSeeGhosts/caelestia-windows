[CmdletBinding()]
param(
    [string]$Base,
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    [string]$RepoRoot
)
$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path }
$required = $true
# Unknown/new events, first pushes and unavailable bases must fail closed to
# a full build. There are no broad path exclusions hiding runtime changes.
if ($EventName -ne 'workflow_dispatch' -and $Base -match '^[a-f0-9]{40}$' -and $Base -ne ('0' * 40)) {
    $ErrorActionPreference = 'Continue'
    $null = & git -C $RepoRoot cat-file -e "${Base}^{commit}" 2>$null
    $basePresent = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if ($basePresent) {
        $files = @(& git -C $RepoRoot diff --name-only --no-renames $Base HEAD --)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine changed source paths.' }
        $docs = '^(README\.md|CONTRIBUTING\.md|\.github/(CONTRIBUTING\.md|PULL_REQUEST_TEMPLATE\.md|ISSUE_TEMPLATE/[^/]+\.(yml|md))|windows/(README\.md|NATIVE-BUILD\.md|ROADMAP\.md|docs/.+\.md|ci/README\.md))$'
        $required = $files.Count -eq 0 -or @($files | Where-Object { $_ -notmatch $docs }).Count -gt 0
    }
}
$value = $required.ToString().ToLowerInvariant()
if ($env:GITHUB_OUTPUT) { "native=$value" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8 }
Write-Output "Native build required: $value"
