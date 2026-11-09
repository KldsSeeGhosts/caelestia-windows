[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) { $RepositoryRoot = Join-Path $PSScriptRoot '..\..' }
$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path

function Get-RequiredText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required policy file is missing: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected,
        [string]$Description
    )
    if (-not $Text.Contains($Expected)) {
        throw "Policy check failed: $Description"
    }
}

$shellWorkflow = Join-Path $root '.github\workflows\windows-build.yml'
$backendWorkflow = Join-Path $root '.github\workflows\windows-tests.yml'
if (Test-Path -LiteralPath $shellWorkflow -PathType Leaf) {
    $workflowPath = $shellWorkflow
    $policyPath = Join-Path $root 'windows\docs\REPOSITORY-POLICY.md'
    $requiredGate = 'Windows validation'
    $issueTracker = 'https://github.com/KldsSeeGhosts/caelestia-windows/issues'
    $expectedJobs = @(
        'Change scope',
        'Fast regressions (${{ matrix.shard }}/3)',
        'Installer and colour regressions (${{ matrix.shard }}/2)',
        'Verified native reuse and offscreen regressions',
        'Backend fixtures and portable tier',
        'Native build and offscreen regressions',
        'Exact-pair receipt',
        'Windows validation',
        'Prepare unsigned corresponding sources',
        'Assemble exact-tested release candidate',
        'Nexus development publication'
    )
    $ownedPaths = @(
        '/.github/workflows/',
        '/windows/ci/',
        '/windows/cmake/',
        '/windows/scripts/Build-Prototype.ps1',
        '/windows/scripts/Test-Validation.ps1',
        '/windows/scripts/Install-Caelestia.ps1',
        '/windows/scripts/Uninstall-Caelestia.ps1',
        '/windows/scripts/Start-DesktopShell.ps1',
        '/windows/scripts/Watch-DesktopShell.ps1',
        '/plugin/src/Caelestia/Windows/',
        '/windows/scripts/NativeAudioSnapshot.cs',
        '/windows/deps/',
        '/.gitmodules',
        '/windows/sources.lock.json'
    )
    $scopeName = 'shell'
} elseif (Test-Path -LiteralPath $backendWorkflow -PathType Leaf) {
    $workflowPath = $backendWorkflow
    $policyPath = Join-Path $root 'REPOSITORY-POLICY.md'
    $requiredGate = 'Build all fixtures, run portable tier'
    $issueTracker = 'https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/issues'
    $expectedJobs = @('Build all fixtures, run portable tier')
    $ownedPaths = @(
        '/.github/workflows/',
        '/CMakeLists.txt',
        '/cmake/',
        '/src/windows/',
        '/flake.nix',
        '/flake.lock',
        '/default.nix',
        '/overlay.nix',
        '/shell.nix'
    )
    $scopeName = 'backend'
} else {
    throw 'Policy check must run from a shell or backend repository root.'
}

$codeowners = Get-RequiredText (Join-Path $root '.github\CODEOWNERS')
$security = Get-RequiredText (Join-Path $root 'SECURITY.md')
$bugTemplate = Get-RequiredText (Join-Path $root '.github\ISSUE_TEMPLATE\bug_report.yml')
$policy = Get-RequiredText $policyPath
$policyNormalized = ($policy -replace '\s+', ' ').Trim()
$workflow = Get-RequiredText $workflowPath

Assert-Contains $codeowners '@KldsSeeGhosts' 'the real maintainer account is missing from CODEOWNERS'
foreach ($ownedPath in $ownedPaths) {
    $linePattern = '(?m)^' + [regex]::Escape($ownedPath) + '\s+@KldsSeeGhosts\s*$'
    if ($codeowners -notmatch $linePattern) {
        throw "Policy check failed: CODEOWNERS does not assign $ownedPath to @KldsSeeGhosts"
    }
}

$jobNames = @(
    [regex]::Matches($workflow, '(?m)^ {4}name:\s*(?<name>.+?)\s*$') |
        ForEach-Object { $_.Groups['name'].Value }
)
if ($jobNames.Count -ne $expectedJobs.Count) {
    throw "Policy check failed: found $($jobNames.Count) job labels, expected $($expectedJobs.Count)"
}
foreach ($jobName in $expectedJobs) {
    if ($jobNames -notcontains $jobName) {
        throw "Policy check failed: source workflow job label is not exact: $jobName"
    }
    Assert-Contains $policy ('`' + $jobName + '`') "policy doc omits workflow job label '$jobName'"
}
Assert-Contains $policy ('Required ' + $scopeName + ' gate: `' + $requiredGate + '`') 'the proposed required gate is missing'
Assert-Contains $policyNormalized 'not claimed as active or verified' 'policy doc must not claim settings were applied'
if ($scopeName -eq 'shell') {
    Assert-Contains $policy 'documentation-only' 'the documentation-only classification path is not documented'
    Assert-Contains $workflow 'needs: [scope, sources]' 'unsigned assembly must start independently of validation'
    Assert-Contains $workflow 'needs: [candidate, pair, validation]' 'publication must require assembly and final validation'
    Assert-Contains $policy 'credential-free sealing precedes signing' 'the delivery job inventory must document sealing'
} else {
    Assert-Contains $policyNormalized 'docs-only changes' 'the backend workflow behavior for documentation-only changes is not documented'
}
Assert-Contains $policy '@KldsSeeGhosts' 'the named maintainer bypass is missing'
Assert-Contains $policy 'v*' 'release-tag protection is not documented'
Assert-Contains $policy 'force pushes' 'force-push restriction is not documented'
Assert-Contains $policy 'deletion' 'branch/tag deletion restriction is not documented'

Assert-Contains $security 'Availability of GitHub' 'private advisory availability must be stated truthfully'
Assert-Contains $security 'has not been verified' 'private advisory availability must not be assumed'
Assert-Contains $security 'public issue tracker' 'the existing safe fallback route is missing'
Assert-Contains $security $issueTracker 'security fallback must use this repository’s existing public tracker'
Assert-Contains $security 'do not include' 'the public fallback must prohibit vulnerability details'
if ($security -match '(?i)mailto:|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}') {
    throw 'Policy check failed: SECURITY.md must not invent or publish an unverified email address'
}

foreach ($fieldId in @('release_build', 'windows_version', 'reproduction', 'expected_actual', 'diagnostics')) {
    Assert-Contains $bugTemplate ('id: ' + $fieldId) "bug form is missing the $fieldId field"
}
if ([regex]::Matches($bugTemplate, '(?m)^\s+required: true\s*$').Count -lt 4) {
    throw 'Policy check failed: release/build, Windows, reproduction, and behavior details must be requested'
}
foreach ($fieldId in @('release_build', 'windows_version', 'reproduction', 'expected_actual')) {
    $fieldPattern = '(?ms)^    id: ' + [regex]::Escape($fieldId) + '\s*$(?:(?!^  - type:).)*?^      required: true\s*$'
    if ($bugTemplate -notmatch $fieldPattern) { throw "Policy check failed: $fieldId must be required" }
}
Assert-Contains $bugTemplate 'Do not report a security vulnerability here' 'bug form must direct security reports to the private route'
if ($scopeName -eq 'shell') {
    if (Test-Path -LiteralPath (Join-Path $root '.github\ISSUE_TEMPLATE\issue.yml')) {
        throw 'Policy check failed: superseded unsanitized bug form remains available'
    }
    $contact = Get-RequiredText (Join-Path $root '.github\ISSUE_TEMPLATE\security_contact.yml')
    Assert-Contains $security 'template=security_contact.yml' 'security fallback must reach the no-details contact form'
    Assert-Contains $contact 'This request is public' 'contact form must disclose public visibility'
    Assert-Contains $contact 'contains no technical details' 'contact form must request no vulnerability details'
    Assert-Contains $contact 'required: true' 'contact form must contain a usable acknowledgement'
    if ($contact -match 'type: (input|textarea|dropdown)') {
        throw 'Policy check failed: security contact form must not solicit report details'
    }
}
Assert-Contains $bugTemplate 'Screenshots are not required' 'screenshots must not be required'
Assert-Contains $bugTemplate 'raw user profile' 'raw profile data must be prohibited'
Assert-Contains $bugTemplate 'not available yet' 'the planned support bundle must not be presented as available'

$publicPolicyText = $policy + $security + $bugTemplate
if ($publicPolicyText -match '(?i)\bERM-[0-9]+\b|\bt3/|\b[A-Z]:[\\/]Users[\\/]') {
    throw 'Policy check failed: public policy text contains an internal tracker, branch, or personal path'
}

Write-Output "PASS: $scopeName repository policy files match the checked-in workflow labels and safety requirements."
Write-Output "PASS: required gate is '$requiredGate'; settings are documented as unverified."
