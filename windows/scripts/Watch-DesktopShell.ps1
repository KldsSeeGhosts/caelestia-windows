[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LaunchSpec
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
Import-CaelestiaDesktopTakeover -ScriptRoot $PSScriptRoot
$spec = Get-Content -LiteralPath $LaunchSpec -Raw | ConvertFrom-Json
$hideTaskbar = $false
$restartOnCrash = $true
$suppression = 'hide'
$restartFrozenShell = $true
if ($spec.ConfigPath -and (Test-Path -LiteralPath $spec.ConfigPath)) {
    $config = Get-Content -LiteralPath $spec.ConfigPath -Raw | ConvertFrom-Json
    foreach ($setting in @('hideTaskbar', 'restartOnCrash')) {
        if ($config.windows -and $config.windows.PSObject.Properties[$setting]) {
            if ($config.windows.$setting -isnot [bool]) { throw "windows.$setting must be a JSON boolean." }
            if ($setting -eq 'hideTaskbar') { $hideTaskbar = $config.windows.$setting }
            else { $restartOnCrash = $config.windows.$setting }
        }
    }
    if ($config.windows -and $config.windows.PSObject.Properties['taskbarSuppression']) {
        $suppression = $config.windows.taskbarSuppression
        if ($suppression -isnot [string] -or $suppression -cnotin @('hide', 'invisible')) {
            throw 'windows.taskbarSuppression must be "hide" or "invisible".'
        }
    }
}
if ($spec.ConfigPath) {
    $shellConfigPath = Join-Path (Split-Path -Parent $spec.ConfigPath) 'shell.json'
    if (Test-Path -LiteralPath $shellConfigPath) {
        $shellConfig = Get-Content -LiteralPath $shellConfigPath -Raw | ConvertFrom-Json
        if ($shellConfig.windows -and $shellConfig.windows.PSObject.Properties['restartFrozenShell']) {
            if ($shellConfig.windows.restartFrozenShell -isnot [bool]) { throw 'windows.restartFrozenShell must be a JSON boolean.' }
            $restartFrozenShell = $shellConfig.windows.restartFrozenShell
        }
    }
}
exit [Caelestia.Takeover.Supervisor]::Run([IO.Path]::GetFullPath($LaunchSpec), $hideTaskbar, $restartOnCrash, ($suppression -ceq 'invisible'), $restartFrozenShell)
