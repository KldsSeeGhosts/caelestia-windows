[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$VCRuntimeRoot
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
$testRoot = Resolve-CaelestiaDirectory (Join-Path $env:TEMP ('caelestia-license-test-' + [guid]::NewGuid().ToString('N')))
$prefix = Join-Path $testRoot 'app'
$profile = Join-Path $testRoot 'profile'
$arguments = @{ BuildRoot = $BuildRoot; QtPrefix = $QtPrefix; Prefix = $prefix; ProfileRoot = $profile }
if ($VCRuntimeRoot) { $arguments.VCRuntimeRoot = $VCRuntimeRoot }
$integration = Get-CaelestiaIntegration $prefix
$pairs = [ordered]@{
    'LICENSE' = 'LICENSE'
    'THIRD-PARTY-NOTICES.md' = 'THIRD-PARTY-NOTICES.md'
    'windows\sources.lock.json' = 'sources.lock.json'
    'windows\deps\m3shapes\LICENSE' = 'M3Shapes-LICENSE'
    'windows\deps\quickshell\LICENSE' = 'Quickshell-LICENSE'
    'windows\deps\quickshell\LICENSE-GPL' = 'GPL-3.0.txt'
    'windows\deps\quickshell\src\windows\third_party\material_color\LICENSE' = 'Quickshell-third-party\material_color\LICENSE'
    'windows\deps\quickshell\src\windows\third_party\virtual_desktop\LICENSE' = 'Quickshell-third-party\virtual_desktop\LICENSE'
    'windows\licenses\fonts\caskaydia-cove\LICENSE' = 'fonts\caskaydia-cove\LICENSE'
    'windows\licenses\fonts\nerd-font-symbols\LICENSE' = 'fonts\nerd-font-symbols\LICENSE'
}
# Verify every actual font notice too, including fonts merged after this test.
foreach ($source in @("$repoRoot\assets", "$repoRoot\windows\assets")) {
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
        if ($file.Name -notmatch '(^|[._-])(LICENSE|LICENCE|COPYING|NOTICE|OFL)([._-].*)?$') { continue }
        $relative = $file.FullName.Substring($source.Length + 1)
        $pairs[$file.FullName.Substring($repoRoot.Length + 1)] = "fonts\$relative"
    }
}
New-Item -ItemType Directory -Path "$profile\config" -Force | Out-Null
# A populated profile needs this prefix's ownership marker (written by an
# earlier install in real use); an unmarked one must be refused.
$foreign = Join-Path $testRoot 'foreign-profile'
New-Item -ItemType Directory -Path $foreign -Force | Out-Null
'not a caelestia profile' | Set-Content -LiteralPath (Join-Path $foreign 'notes.txt')
$refused = $false
$foreignArguments = $arguments.Clone()
$foreignArguments.ProfileRoot = $foreign
try { & "$PSScriptRoot\Install-Caelestia.ps1" @foreignArguments } catch { $refused = "$_" -match 'ownership marker' }
if (-not $refused -or (Test-Path -LiteralPath (Join-Path $foreign 'profile-owner.json'))) { throw 'An unmarked populated profile was not refused.' }
Write-CaelestiaProfileOwner $profile $prefix 'license-test' $true
$marker = Join-Path $profile 'config\packaging-test.txt'
'preserve this profile' | Set-Content -LiteralPath $marker
$markerHash = (Get-FileHash -LiteralPath $marker).Hash
try {
    foreach ($phase in @('install', 'update')) {
        & "$PSScriptRoot\Install-Caelestia.ps1" @arguments
        foreach ($entry in $pairs.GetEnumerator()) {
            $source = Join-Path $repoRoot $entry.Key
            $target = Join-Path "$prefix\licenses" $entry.Value
            if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
                (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
                throw "Missing or changed $phase notice: $($entry.Value)"
            }
        }
        foreach ($file in @('LGPL-3.0.txt', 'GPL-3.0.txt')) {
            if ((Get-FileHash -LiteralPath "$prefix\licenses\$file").Hash -ne
                (Get-FileHash -LiteralPath "$prefix\licenses\Qt\$file").Hash) { throw "Qt license differs: $file" }
        }
        # Check all prefix-supplied license files and SBOMs, not just one sample.
        foreach ($file in Get-ChildItem -LiteralPath $QtPrefix -Recurse -File) {
            $relative = $file.FullName.Substring($QtPrefix.Length + 1)
            $target = $null
            if ($relative.StartsWith('licenses\', [StringComparison]::OrdinalIgnoreCase)) {
                $target = Join-Path "$prefix\licenses\Qt" $relative.Substring(9)
            } elseif ($relative.StartsWith('sbom\', [StringComparison]::OrdinalIgnoreCase)) {
                $target = Join-Path "$prefix\licenses\Qt-sbom" $relative.Substring(5)
            } elseif ($relative -imatch '(^|\\)LICENSES\\') {
                # SPDX-named texts (LGPL-3.0-only.txt, ...) keep their Qt-relative path.
                $target = Join-Path "$prefix\licenses\Qt" $relative
            } elseif ($file.Name -match '(^|[._-])(LICENSE|LICENCE|COPYING|NOTICE|OFL)([._-].*)?$') {
                $target = Join-Path "$prefix\licenses\Qt" $relative
            }
            if ($target -and (-not (Test-Path -LiteralPath $target) -or
                (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash)) {
                throw "Missing or changed Qt notice: $relative"
            }
        }
        # Deployed Qt modules must come with Qt's license texts or SBOMs.
        if ((Get-ChildItem -LiteralPath $prefix -Filter 'Qt6*.dll' | Select-Object -First 1) -and
            -not (Get-ChildItem -LiteralPath "$prefix\licenses\Qt", "$prefix\licenses\Qt-sbom" -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('LGPL-3.0.txt', 'GPL-3.0.txt') } | Select-Object -First 1)) {
            throw "Qt libraries are deployed but only the generic LGPL/GPL texts accompany them ($phase)."
        }
        if ((Get-FileHash -LiteralPath $marker).Hash -ne $markerHash) { throw 'Profile changed.' }
        if (-not (Test-Path -LiteralPath $integration.Shortcut)) { throw 'Install shortcut missing.' }
        Write-Output "LICENSE_${phase}_PASS"
    }
    & "$PSScriptRoot\Uninstall-Caelestia.ps1" -Prefix $prefix
    if (Test-Path -LiteralPath $prefix) { throw 'Prefix and its licenses remain after uninstall.' }
    if (Test-Path -LiteralPath $integration.Shortcut) { throw 'Shortcut remains after uninstall.' }
    if ((Get-FileHash -LiteralPath $marker).Hash -ne $markerHash) { throw 'Uninstall changed the retained profile.' }
    if (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $integration.RunName -ErrorAction SilentlyContinue) {
        throw 'Unexpected autostart entry.'
    }
    Write-Output 'LICENSE_UNINSTALL_PASS'
    Write-Output 'INSTALL_LICENSES_PASS'
} finally {
    if (Test-Path -LiteralPath "$prefix\install.json") {
        & "$PSScriptRoot\Uninstall-Caelestia.ps1" -Prefix $prefix
    }
    # Only this invocation's resolved TEMP child can be recursively removed.
    $safeRoot = Resolve-CaelestiaDirectory $testRoot
    if ((Split-Path -Parent $safeRoot) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
        (Split-Path -Leaf $safeRoot) -notlike 'caelestia-license-test-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $safeRoot -Recurse -Force
}
