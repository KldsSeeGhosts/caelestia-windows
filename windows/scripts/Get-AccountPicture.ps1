[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CacheRoot,
    [string]$RegistryRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AccountPicture',
    [string]$PictureDirectory = (Join-Path $env:APPDATA 'Microsoft\Windows\AccountPictures')
)

# Read the existing account picture only. Extract packed accountpicture-ms
# images into the isolated profile, never change Windows account settings.
$ErrorActionPreference = 'Stop'
$candidates = @()
if (Test-Path -LiteralPath $RegistryRoot) {
    $keys = @(Get-Item -LiteralPath $RegistryRoot) + @(Get-ChildItem -LiteralPath $RegistryRoot -Recurse)
    foreach ($key in $keys) {
        $values = Get-ItemProperty -LiteralPath $key.PSPath
        $candidates += @($values.PSObject.Properties | Where-Object {
            $_.Name -like 'Image*' -and $_.Value -is [string] -and (Test-Path -LiteralPath $_.Value -PathType Leaf)
        } | ForEach-Object { Get-Item -LiteralPath $_.Value })
    }
}
if (Test-Path -LiteralPath $PictureDirectory -PathType Container) {
    $candidates += @(Get-ChildItem -LiteralPath $PictureDirectory -File |
        Where-Object { $_.Extension -in @('.png', '.jpg', '.jpeg', '.bmp', '.accountpicture-ms') })
}
$candidates = @($candidates | Sort-Object LastWriteTimeUtc -Descending)
Add-Type -AssemblyName System.Drawing
foreach ($file in $candidates) {
    if ($file.Extension -ne '.accountpicture-ms') {
        return ([Uri]$file.FullName).AbsoluteUri
    }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $best = $null
    try {
        for ($i = 0; $i -lt $bytes.Length - 8; ++$i) {
            $jpeg = $bytes[$i] -eq 255 -and $bytes[$i + 1] -eq 216 -and $bytes[$i + 2] -eq 255
            $png = $bytes[$i] -eq 137 -and $bytes[$i + 1] -eq 80 -and $bytes[$i + 2] -eq 78 -and $bytes[$i + 3] -eq 71
            if (-not ($jpeg -or $png)) { continue }
            $stream = [IO.MemoryStream]::new($bytes, $i, $bytes.Length - $i, $false)
            $image = $null
            try {
                $image = [Drawing.Image]::FromStream($stream, $false, $true)
                if (-not $best -or $image.Width -gt $best.Width) {
                    if ($best) { $best.Dispose() }
                    $best = [Drawing.Bitmap]::new($image)
                }
            } catch {
                # A signature inside compressed data is not an embedded image.
            } finally {
                if ($image) { $image.Dispose() }
                $stream.Dispose()
            }
        }
        if ($best) {
            New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
            $target = Join-Path $CacheRoot 'account-picture.png'
            $best.Save($target, [Drawing.Imaging.ImageFormat]::Png)
            return ([Uri][IO.Path]::GetFullPath($target)).AbsoluteUri
        }
    } finally {
        if ($best) { $best.Dispose() }
    }
}
$face = Join-Path $env:USERPROFILE '.face'
if (Test-Path -LiteralPath $face -PathType Leaf) { return ([Uri]$face).AbsoluteUri }
return ''
