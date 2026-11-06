[CmdletBinding()]
param(
    [ValidateSet('pinned', 'candidate')][string]$Mode = 'pinned',
    [string]$BackendSha,
    [Parameter(Mandatory)][string]$ShellSha,
    [Parameter(Mandatory)][string]$ShellRoot,
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][string]$Results,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$requestArguments = @('-I', '-B', "$PSScriptRoot\pair_result.py", 'resolve', '--mode', $Mode,
    '--shell-sha', $ShellSha, '--shell', $ShellRoot, '--candidate-root', $CandidateRoot,
    '--results', $Results)
# Windows PowerShell drops empty native arguments; omit the optional flag too.
if ($BackendSha) { $requestArguments += @('--backend-sha', $BackendSha) }
& $Python @requestArguments
if ($LASTEXITCODE -ne 0) { throw 'Exact pair request refused; see pair-request.json refusal category.' }
