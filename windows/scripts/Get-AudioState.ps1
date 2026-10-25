[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
if (-not ('Caelestia.AudioSnapshot.Native' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'NativeAudioSnapshot.cs')
}
# No process/application metadata, recording, audio playback or settings writes.
$result = [Caelestia.AudioSnapshot.Native]::Capture() | ConvertTo-Json -Depth 8
if ($OutputPath) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $result, (New-Object Text.UTF8Encoding($false)))
}
$result
