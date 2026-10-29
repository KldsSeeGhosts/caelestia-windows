[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LaunchSpec
)
$ErrorActionPreference = 'Stop'
$assembly = Join-Path $PSScriptRoot 'DesktopTakeover.dll'
if (Test-Path -LiteralPath $assembly) { Add-Type -Path $assembly }
else {
    # Repository prototype/test launches still work without an installed DLL.
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
}
$spec = Get-Content -LiteralPath $LaunchSpec -Raw | ConvertFrom-Json
$hideTaskbar = $false
$restartOnCrash = $true
$suppression = 'hide'
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
exit [Caelestia.Takeover.Supervisor]::Run([IO.Path]::GetFullPath($LaunchSpec), $hideTaskbar, $restartOnCrash, ($suppression -ceq 'invisible'))
