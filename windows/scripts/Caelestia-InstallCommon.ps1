# Shared by repository and installed scripts. No machine-wide changes.
$ErrorActionPreference = 'Stop'

function Resolve-CaelestiaDirectory([string]$Path) {
    if (-not $Path -or $Path.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) {
        throw 'A nonempty Windows directory path is required.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw "Unsafe directory: $full" }
    foreach ($protected in @($env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
        if ($protected -and ($protected -eq $full -or $protected.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw "Directory contains a protected Windows/user location: $full"
        }
    }
    # Refuse junction/symlink traversal before copying or recursive removal.
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Directory must not traverse a file or reparse point: $ancestor"
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $full
}

function Read-CaelestiaInstall([string]$Prefix) {
    $record = Get-Content -LiteralPath (Join-Path $Prefix 'install.json') -Raw | ConvertFrom-Json
    if ($record.product -ne 'caelestia-windows' -or $record.version -ne 1 -or $record.prefix -ne $Prefix) {
        throw "Not a recognized Caelestia installation: $Prefix"
    }
    return $record
}

function Get-CaelestiaProcesses([string]$Prefix) {
    $exe = Join-Path $Prefix 'qs.exe'
    return @(Get-Process -Name qs -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
}

function Get-CaelestiaIntegration([string]$Prefix) {
    $default = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows')).TrimEnd('\')
    $suffix = ''
    if ($Prefix -ne $default) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $suffix = '-' + ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Prefix.ToLowerInvariant())))).Replace('-', '').Substring(0, 12) }
        finally { $hash.Dispose() }
    }
    return @{
        RunName = "CaelestiaWindows$suffix"
        Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) "Caelestia Windows$suffix.lnk"
    }
}
