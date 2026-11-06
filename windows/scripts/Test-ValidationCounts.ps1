#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'Test-Validation.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Validation runner does not parse.' }
$definition = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ValidationStep'
}, $true)
if (-not $definition) { throw 'Validation step function is missing.' }
# Load the actual production runner function without executing its suite.
. ([scriptblock]::Create($definition.Extent.Text))
$OutputRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-count-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$results = New-Object 'System.Collections.Generic.List[object]'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    $cases = @(
        @{ name = 'node-empty'; output = '# tests 0'; pattern = '(?m)^# tests ([0-9]+)\s*$'; count = 0; code = 1 },
        @{ name = 'node-positive'; output = '# tests 3'; pattern = '(?m)^# tests ([0-9]+)\s*$'; count = 3; code = 0 },
        @{ name = 'python-empty'; output = 'Ran 0 tests in 0.001s'; pattern = '(?m)^Ran ([0-9]+) tests?\b'; count = 0; code = 1 },
        @{ name = 'python-positive'; output = 'Ran 1 test in 0.001s'; pattern = '(?m)^Ran ([0-9]+) tests?\b'; count = 1; code = 0 },
        @{ name = 'missing-summary'; output = 'OK'; pattern = '(?m)^Ran ([0-9]+) tests?\b'; count = $null; code = 1 }
    )
    foreach ($case in $cases) {
        $null = Invoke-ValidationStep $case.name $powershell @(
            '-NoProfile', '-NonInteractive', '-Command', ("Write-Output '" + $case.output + "'; exit 0")
        ) $case.pattern
        $actual = $results[$results.Count - 1]
        if ($actual.exitCode -ne $case.code -or $actual.testCount -ne $case.count) {
            throw "Incorrect test-count outcome: $($case.name)"
        }
    }
    Write-Output "PASS validation counts: $($cases.Count) zero/nonzero/missing-summary cases."
} finally {
    $resolved = (Resolve-Path -LiteralPath $OutputRoot).Path
    $parent = [IO.Path]::GetTempPath().TrimEnd('\')
    if ((Split-Path -Parent $resolved) -ne $parent -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-count-test-*') { throw 'Unsafe count-test cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
