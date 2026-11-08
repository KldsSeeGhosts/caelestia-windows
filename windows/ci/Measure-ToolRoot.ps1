#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$spec = Get-Content -LiteralPath "$PSScriptRoot\..\toolchain.json" -Raw | ConvertFrom-Json
# Fixed public labels, never machine paths or arbitrary directory/file names.
$directories = [ordered]@{
    Qt = 'Qt'
    LLVM = $spec.llvmDirectory
    downloads = 'downloads'
    pip = 'pip'
    deps = 'deps'
    tools = 'tools'
}
$rows = foreach ($label in $directories.Keys) {
    $path = Join-Path $ToolRoot $directories[$label]
    $bytes = [long]0
    $files = [long]0
    $exists = Test-Path -LiteralPath $path -PathType Container
    if ($exists) {
        Get-ChildItem -LiteralPath $path -File -Recurse -Force | ForEach-Object {
            $bytes += $_.Length
            $files++
        }
    }
    [ordered]@{ directory = $label; exists = $exists; bytes = $bytes; files = $files }
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
[ordered]@{ schemaVersion = 1; directories = @($rows) } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
