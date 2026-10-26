[CmdletBinding()]
param()

# The combined launcher remains usable with its fixed palette when the optional
# wallpaper-scheme Python runtime has not been installed.
$ErrorActionPreference = 'Stop'
foreach ($name in @('py', 'python')) {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    # Windows' Store alias is not an installed interpreter.
    if (-not $command -or $command.Source -like '*\Microsoft\WindowsApps\*') { continue }
    try {
        $arguments = @('-c', 'import sys; print(sys.executable)')
        if ($name -eq 'py') { $arguments = @('-3') + $arguments }
        $interpreter = & $command.Source @arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $interpreter -and (Test-Path -LiteralPath "$interpreter" -PathType Leaf)) {
            return [pscustomobject]@{ available = $true; python = "$interpreter"; fallback = $false }
        }
    } catch {
        # A launcher without an installed interpreter also takes the fallback.
    }
}
Write-Warning 'Python 3 (py/python) is missing or unavailable. Dynamic colour generation is unavailable; Caelestia will use the fixed palette. Install Python 3 before using wallpaper-derived schemes.'
[pscustomobject]@{ available = $false; python = ''; fallback = $true }
