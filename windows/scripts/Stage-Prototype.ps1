[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ProfileRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$Destination = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# Copy an explicit audited subset. Never launch or copy the root shell.qml.
$files = [ordered]@{
    'windows/prototype/shell.qml' = 'shell.qml'
    'windows/prototype/services/Colours.qml' = 'services/Colours.qml'
    'services/Time.qml' = 'services/Time.qml'
    'components/Anim.qml' = 'components/Anim.qml'
    'components/CAnim.qml' = 'components/CAnim.qml'
    'components/StyledRect.qml' = 'components/StyledRect.qml'
    'components/StyledText.qml' = 'components/StyledText.qml'
    'components/MaterialIcon.qml' = 'components/MaterialIcon.qml'
    'components/ClipRect.qml' = 'components/ClipRect.qml'
    'LICENSE' = 'LICENSE'
    'modules/bar/components/Clock.qml' = 'modules/bar/components/Clock.qml'
    'modules/dashboard/dash/DateTime.qml' = 'modules/dashboard/dash/DateTime.qml'
    'assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf' =
        'assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf'
    'assets/google-sans-flex/LICENSE' = 'assets/google-sans-flex/LICENSE'
}
$manifest = foreach ($entry in $files.GetEnumerator()) {
    $source = Join-Path $repoRoot $entry.Key
    $target = Join-Path $Destination $entry.Value
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
    if ($entry.Value -eq 'shell.qml') {
        $shell = [IO.File]::ReadAllText($target)
        $overrides = @("DataDir $ProfileRoot\data", "StateDir $ProfileRoot\state", "CacheDir $ProfileRoot\cache")
        $header = ($overrides | ForEach-Object { "//@ pragma $_" }) -join "`n"
        [IO.File]::WriteAllText($target, "$header`n$shell", (New-Object Text.UTF8Encoding($false)))
    }
    [ordered]@{
        source = $entry.Key; staged = $entry.Value
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'sources.json') -Encoding UTF8
Write-Output $Destination
