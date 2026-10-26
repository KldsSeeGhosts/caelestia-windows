[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LaunchSpec
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
$spec = Get-Content -LiteralPath $LaunchSpec -Raw | ConvertFrom-Json
$hideTaskbar = $false
$restartOnCrash = $true
if ($spec.ConfigPath -and (Test-Path -LiteralPath $spec.ConfigPath)) {
    $config = Get-Content -LiteralPath $spec.ConfigPath -Raw | ConvertFrom-Json
    foreach ($setting in @('hideTaskbar', 'restartOnCrash')) {
        if ($config.windows -and $config.windows.PSObject.Properties[$setting]) {
            if ($config.windows.$setting -isnot [bool]) { throw "windows.$setting must be a JSON boolean." }
            if ($setting -eq 'hideTaskbar') { $hideTaskbar = $config.windows.$setting }
            else { $restartOnCrash = $config.windows.$setting }
        }
    }
}
exit [Caelestia.Takeover.Supervisor]::Run([IO.Path]::GetFullPath($LaunchSpec), $hideTaskbar, $restartOnCrash)
