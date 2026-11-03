[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Static guard for the rule that nothing probes a scheme generation after the
# shell has been stopped. The post-stop setter is structurally probe-free, and
# the selection calls stay before the Quit that stops the old shell.
$script:assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Read-ScriptAst([string]$Path) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) "PowerShell parse failed: $Path"
    return $ast
}
function Get-FunctionAst($Ast, [string]$Name) {
    return $Ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
}
function Get-CommandCalls($Ast, [string]$Name) {
    return @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $Name
    }, $true))
}
function Get-ParameterNames($CommandAst) {
    return @($CommandAst.CommandElements |
        Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } |
        ForEach-Object { $_.ParameterName })
}

$probeFunctions = @(
    'Get-CaelestiaVerifiedSchemeGeneration', 'Select-CaelestiaSchemeGeneration', 'Select-CaelestiaRestoreScheme',
    'Test-CaelestiaSchemeHealth', 'Invoke-CaelestiaBounded', 'Resolve-CaelestiaSystemPython', 'Install-CaelestiaSchemeRuntime'
)
$forbiddenSetterParameters = @('NoProbe', 'BudgetSeconds', 'CandidateSeconds')

$commonPath = Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1'
$common = Read-ScriptAst $commonPath
$setter = Get-FunctionAst $common 'Set-CaelestiaSchemeRuntimeForRevision'
Assert ($null -ne $setter) 'The post-stop scheme setter is missing.'
$setterParameters = @($setter.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($name in $forbiddenSetterParameters) {
    Assert ($setterParameters -notcontains $name) "The post-stop setter still accepts -$name, so it can be asked to probe."
}
Assert ($setterParameters -contains 'Verified') 'The post-stop setter must accept a decision made before the stop.'

# The setter must not reach any function that starts a process or probes health.
foreach ($call in @($setter.Body.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $probeFunctions -contains $node.GetCommandName()
}, $true))) {
    throw "The post-stop setter calls probing command '$($call.GetCommandName())'."
}
Assert (@($setter.Body.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Start' -and
        $node.Expression.Extent.Text -match 'Diagnostics\.Process'
}, $true)).Count -eq 0) 'The post-stop setter starts a process directly.'

# Every production script: the old switch is gone, and no caller can pass a
# probe-enabling argument to the setter.
$production = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | Where-Object { $_.Name -notlike 'Test-*' })
foreach ($script in $production) {
    $ast = Read-ScriptAst $script.FullName
    $oldSwitch = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -eq 'NoProbe'
    }, $true))
    Assert ($oldSwitch.Count -eq 0) "$($script.Name) still declares a NoProbe parameter."
    foreach ($call in @(Get-CommandCalls $ast 'Set-CaelestiaSchemeRuntimeForRevision')) {
        $names = Get-ParameterNames $call
        foreach ($name in $forbiddenSetterParameters) {
            Assert ($names -notcontains $name) "$($script.Name) passes -$name to the post-stop setter."
        }
    }
}

# Both activation paths decide the target and the restore generation before
# the first Quit. Nothing may probe after it.
$versions = Read-ScriptAst (Join-Path $PSScriptRoot 'Caelestia-Versions.ps1')
foreach ($name in @('Install-CaelestiaVersion', 'Switch-CaelestiaVersion')) {
    $function = Get-FunctionAst $versions $name
    Assert ($null -ne $function) "Missing activation function: $name"
    $quits = @($function.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text -match '(?m)-Command\s+Quit\b'
    }, $true))
    Assert ($quits.Count -ge 1) "$name never stops the old shell."
    $firstQuit = ($quits | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1).Extent.StartOffset
    $lateProbes = @($function.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $probeFunctions -contains $node.GetCommandName()
    }, $true) | Where-Object { $_.Extent.StartOffset -gt $firstQuit })
    Assert ($lateProbes.Count -eq 0) "$name probes a generation after it has stopped the shell."
}

# Recovery relaunches a stopped shell from decisions made earlier; it must not
# reach a probing command at all.
$restore = Get-FunctionAst $common 'Restore-CaelestiaUpdate'
Assert ($null -ne $restore) 'Missing activation recovery function.'
Assert (@($restore.Body.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $probeFunctions -contains $node.GetCommandName()
}, $true)).Count -eq 0) 'Recovery probes a generation after the shell has stopped.'

Write-Output "PASS scheme probe guard: $script:assertions static assertions; the post-stop setter cannot probe and no production caller enables it."
