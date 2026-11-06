#requires -Version 5.1
[CmdletBinding()]
param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
foreach ($name in @('Resolve-PairRequest.ps1', 'Invoke-PairIntegration.ps1')) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        "$root\windows\ci\$name", [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Pair entry point does not parse: $name" }
}
$workflow = [IO.File]::ReadAllText("$root\.github\workflows\windows-build.yml")
$blocks = [regex]::Matches($workflow, '(?m)^        run: \|\r?\n((?:          [^\r\n]*\r?\n|\r?\n)+)')
if (-not $blocks.Count) { throw 'Workflow command blocks were not discovered.' }
foreach ($block in $blocks) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Workflow PowerShell does not parse: $($parseErrors[0].Message)" }
}
& $Python -I -B -m unittest discover -s "$root\windows\tests\pair_contract" -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { throw 'Exact-pair contract regressions failed.' }
