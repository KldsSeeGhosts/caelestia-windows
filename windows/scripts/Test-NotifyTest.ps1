[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Headless contract/routing checks only. Never submit a toast or use a real
# installation/profile, even when this test is run on Windows.
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
function Assert-Refused([scriptblock]$Action, [string]$Reason) {
    $failed = $false
    try { & $Action } catch { $failed = $_.Exception.Message -like "*$Reason*" }
    Assert $failed "Expected refusal: $Reason"
}

$launcher = Join-Path $PSScriptRoot 'Start-Caelestia.ps1'
$entry = Join-Path $PSScriptRoot 'Start-CaelestiaEntry.ps1'
$ast = Read-ScriptAst $launcher
$entryAst = Read-ScriptAst $entry
foreach ($scriptAst in @($ast, $entryAst)) {
    $parameter = $scriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Command' }
    $validateSet = $parameter.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateSet' }
    Assert ('NotifyTest' -in $validateSet.PositionalArguments.Value) 'Launcher must accept NotifyTest.'
}
$branches = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$Command -eq ''NotifyTest'''
}, $true))
Assert ($branches.Count -eq 1) 'Expected one NotifyTest branch.'
$branch = $branches[0].Clauses[0].Item2
$source = $branch.Extent.Text
Assert ($branches[0].Extent.StartOffset -lt $ast.Extent.Text.IndexOf(". (Join-Path `$PSScriptRoot 'Caelestia-InstallCommon.ps1')")) 'NotifyTest must not read installation/profile state.'

$strings = @($branch.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true))
$payloads = @($strings | Where-Object { $_.Value.StartsWith('<toast>') })
Assert ($payloads.Count -eq 1) 'Expected one literal, non-interpolated toast payload.'
$xml = [xml]$payloads[0].Value
Assert ($xml.toast.visual.binding.template -eq 'ToastGeneric') 'Native listener needs a ToastGeneric binding.'
$texts = @($xml.SelectNodes('/toast/visual/binding/text') | ForEach-Object { $_.InnerText })
Assert ($texts.Count -eq 2 -and $texts[0] -ceq 'Caelestia test notification' -and
    $texts[1] -ceq 'This is a test notification. No user data is included.') 'Toast text must be fixed and contain no user data.'
Assert ($xml.SelectNodes('//@*').Count -eq 1 -and $xml.SelectNodes('//text').Count -eq 2 -and
    $xml.SelectNodes('//*').Count -eq 5) 'Do not add activation, images, priority/scenario or other payload data.'
Assert ($strings.Value -contains '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe') 'Reuse the existing inbox sender identity.'
Assert ($source -match '\[Windows.UI.Notifications.ToastNotificationManager\]::CreateToastNotifier\(\$appId\)' -and
    $source -match '\[Windows.UI.Notifications.ToastNotification\]::new\(\$xml\)' -and
    $source -match '\$notifier.Show\(\$toast\)') 'Test must submit a real Windows toast, not a local QML substitute.'
Assert ($source -match 'if \(\$notifier.Setting.ToString\(\) -ne ''Enabled''\)') 'Disabled senders must be refused, not enabled.'
Assert ($source -match '-NoLogo -NoProfile -NonInteractive -File \$PSCommandPath -Command NotifyTest' -and
    $source -match 'if \(\$LASTEXITCODE -ne 0\)') 'Core handoff must not load a profile and must propagate failure.'
$calls = @($branch.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
Assert (@($calls | Where-Object { $_ -notin @('Join-Path', 'Write-Output') }).Count -eq 0) 'NotifyTest must not invoke IPC, settings writes, permission requests or other scripts.'
Assert ($source -notmatch '(?i)notifySend|requestSystemNotificationAccess|setMirroring|mirrorSystemNotifications\s*=|Invoke-CaelestiaIpc|ExecutionPolicy') 'NotifyTest must not bypass delivery or consent.'

# Run the production Core handoff block with a function in place of the inbox
# executable. Neither WinRT nor a child process is invoked by this fixture.
$core = $branch.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$PSVersionTable.PSEdition -eq ''Core'''
}, $true)
Assert ($null -ne $core) 'Missing Core handoff.'
$handoffBody = $core.Clauses[0].Item2.Extent.Text
$handoff = [scriptblock]::Create($handoffBody.Substring(1, $handoffBody.Length - 2))
function Test-CoreHandoff([int]$ExitCode) {
    function Join-Path($Path, $ChildPath) {
        Assert ($ChildPath -eq 'System32\WindowsPowerShell\v1.0\powershell.exe') 'Use inbox Windows PowerShell, not PATH lookup.'
        return 'Invoke-FixturePowerShell'
    }
    function Invoke-FixturePowerShell([switch]$NoLogo, [switch]$NoProfile, [switch]$NonInteractive, $File, $Command) {
        # An extracted scriptblock has no PSCommandPath; its use as -File's
        # argument is checked against the original AST above.
        Assert ($NoLogo -and $NoProfile -and $NonInteractive -and $Command -eq 'NotifyTest') 'Wrong Core handoff arguments.'
        $global:LASTEXITCODE = $ExitCode
    }
    & $handoff
}
$savedExitCode = $global:LASTEXITCODE
try {
    Test-CoreHandoff 0
    Assert-Refused { Test-CoreHandoff 1 } 'Windows PowerShell could not submit the test toast.'
} finally { $global:LASTEXITCODE = $savedExitCode }

Assert-Refused { & $launcher -Command NotifyTest -Smoke } '-Smoke requires -Command Start.'
Assert-Refused { & $launcher -Command NotifyTest -ScreenIndex 0 } '-ScreenIndex requires -Smoke.'
if ($env:OS -ne 'Windows_NT') {
    Assert-Refused { & $launcher -Command NotifyTest } 'NotifyTest requires an interactive Windows desktop.'
}

# Exercise the installed stable-root entry with isolated stubs. Resolve the
# selected payload, not an older running payload that may lack this command.
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-notifytest-' + [guid]::NewGuid().ToString('N'))
try {
    $payload = Join-Path $root 'versions/selected'
    $null = [IO.Directory]::CreateDirectory($payload)
    Copy-Item -LiteralPath $entry -Destination (Join-Path $root 'Start-Caelestia.ps1')
    [IO.File]::WriteAllText((Join-Path $root 'Caelestia-InstallCommon.ps1'), @'
function Resolve-CaelestiaDirectory([string]$Path) { return $Path }
function Resolve-CaelestiaRuntimePrefix([string]$Prefix, [switch]$Running) {
    if ($Running) { throw 'NotifyTest must not select the running payload.' }
    return Join-Path $Prefix 'versions/selected'
}
'@)
    [IO.File]::WriteAllText((Join-Path $payload 'Start-Caelestia.ps1'), @'
param($Prefix, $Command)
if ($Command -ne 'NotifyTest' -or $Prefix -ne $PSScriptRoot) { throw 'Incorrect command/prefix forwarding.' }
'NotifyTest routed'
'@)
    Assert ((& (Join-Path $root 'Start-Caelestia.ps1') -Command NotifyTest) -eq 'NotifyTest routed') 'Stable-root command did not reach the selected launcher.'
} finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
Write-Output "PASS NotifyTest: $script:assertions headless assertions; no native toast submitted."
