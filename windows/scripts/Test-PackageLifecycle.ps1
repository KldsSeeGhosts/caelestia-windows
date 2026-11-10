#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Package,
    [string]$PreviousPackage,
    [string]$OutputRoot,
    # Server CI exercises transactions, not Windows 11 installation acceptance.
    [switch]$ServerTransactionFixture
)
$ErrorActionPreference = 'Stop'
$oldQtPlatform = $env:QT_QPA_PLATFORM
$env:QT_QPA_PLATFORM = 'offscreen'
$Package = (Resolve-Path -LiteralPath $Package).Path
$packageHash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
$root = Join-Path ([IO.Path]::GetTempPath()) ('cpl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
if (-not $OutputRoot) { $OutputRoot = $root + '-results' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'Choose a new results directory.' }
New-Item -ItemType Directory -Path $OutputRoot, $root | Out-Null
$oldIntegration = $env:CAELESTIA_TEST_INTEGRATION_ROOT
$env:CAELESTIA_TEST_INTEGRATION_ROOT = Join-Path $root 'integration'
$results = [Collections.Generic.List[object]]::new()
$receipt = $null
$manifestHash = ''
$previousHash = if ($PreviousPackage) { (Get-FileHash -LiteralPath $PreviousPackage).Hash } else { '' }

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Case([string]$Name, [scriptblock]$Action) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $row = [ordered]@{
        case = $Name; outcome = 'fail'; packageSha256 = $packageHash
        manifestSha256 = $manifestHash; toolchain = $receipt
        previousPackageSha256 = $previousHash
        previousMode = $(if ($PreviousPackage) { 'previous-zip' } else { 'synthesized-older-metadata-same-payload' })
        serverTransactionFixture = [bool]$ServerTransactionFixture
        seconds = 0; detail = ''
    }
    try { & $Action | Out-Null; $row.outcome = 'pass' }
    catch { $row.detail = $_.Exception.Message; throw }
    finally {
        $row.manifestSha256 = $manifestHash
        $row.toolchain = $receipt
        $row.seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
        $results.Add($row)
        $results | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath "$OutputRoot\results.json" -Encoding UTF8
        Write-Output ($row | ConvertTo-Json -Depth 30 -Compress)
    }
}
function Assert-Refused([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected refusal '$Pattern', got '$message'."
}

# Load only the checkout's reviewed, pure-data verifier functions. Never execute
# an archive's bootstrap until all extracted files pass this verifier.
$tokens = $null; $parseErrors = $null
$trusted = Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($trusted, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Trusted verifier does not parse.' }
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Expand-Package([string]$Zip, [string]$Destination) {
    $Destination = Assert-ReleaseDirectory $Destination
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $seen = @{}
        $top = @()
        # Validate the complete central directory before creating any files.
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.TrimEnd('/')
            Assert-ReleaseComponents $relative.Split('/')
            Assert-True (-not $seen.ContainsKey($relative)) 'Duplicate ZIP path.'
            $seen[$relative] = $true
            Assert-True (($entry.ExternalAttributes -band 0x400) -eq 0 -and
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -ne 0xA000) 'ZIP contains a link.'
            $top += $relative.Split('/')[0]
        }
        $top = @($top | Select-Object -Unique)
        Assert-True ($top.Count -eq 1) 'ZIP requires one bundle root.'
        foreach ($entry in $archive.Entries) {
            $target = Resolve-ReleaseFile $Destination $entry.FullName.TrimEnd('/')
            if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
            else {
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target)
            }
        }
        return Join-Path $Destination $top[0]
    } finally { $archive.Dispose() }
}
function Invoke-PackageInstall([string]$Bundle, [string]$Prefix, [string]$Profile, [string]$Injection = '',
    [string]$RuntimeFixture = '') {
    $text = Get-Content -LiteralPath "$Bundle\Install-CaelestiaRelease.ps1" -Raw
    # All mutations are confined to this test's in-memory script block. No
    # production switch, environment bypass or package-file edit is introduced.
    if ($ServerTransactionFixture) {
        $boundary = 'if ([Environment]::OSVersion.Version.Build -lt 22000) {'
        Assert-True ($text.Contains($boundary)) 'OS fixture boundary changed.'
        $text = $text.Replace($boundary, 'if ($false) { # Server transaction fixture only')
    }
    if ($RuntimeFixture) {
        $boundary = 'if (-not (Test-ReleaseVCRuntime ([version]$release.prerequisites.visualCppRuntime.minimumVersion))) {'
        Assert-True ($text.Contains($boundary)) 'Runtime fixture boundary changed.'
        $probe = if ($RuntimeFixture -eq 'missing') {
            'Test-ReleaseVCRuntimeVersions 0 "" @() $MinimumVersion'
        } else {
            'Test-ReleaseVCRuntimeVersions 1 "v14.0.0.0" @([version]"14.0.0.0", [version]"14.0.0.0", [version]"14.0.0.0") $MinimumVersion'
        }
        $text = $text.Replace($boundary,
            ('function Test-ReleaseVCRuntime([version]$MinimumVersion) { ' + $probe + " }`n" + $boundary))
    }
    $Injection = @'
function New-CaelestiaLaunchTask { throw 'Package tests must never request a launch task.' }
function Start-CaelestiaDetached { throw 'Package tests must never launch the shell.' }
'@ + "`n" + $Injection
    if ($Injection) {
        $boundary = ". (Join-Path `$payloadSource 'Caelestia-InstallCommon.ps1')"
        Assert-True ($text.Contains($boundary)) 'Import fixture boundary changed.'
        $text = $text.Replace($boundary, $boundary + "`n" + $Injection)
    }
    & ([scriptblock]::Create($text)) -BundleRoot $Bundle -Prefix $Prefix -ProfileRoot $Profile
}
function Get-Selector([string]$Prefix) {
    Get-Content -LiteralPath "$Prefix\install.json" -Raw | ConvertFrom-Json
}
function Assert-Preserved {
    Assert-True ((Get-FileHash -LiteralPath $config).Hash -eq $configHash) 'Configuration changed.'
}
try {
    Invoke-Case 'extract-and-verify-before-execution' {
        $script:bundle = Expand-Package $Package (Join-Path $root 'extracted')
        $verified = Test-ReleaseBundle $bundle
        $script:manifestHash = $verified.Sha256
        $script:receipt = $verified.Manifest.toolchain
        Assert-True ($null -ne $receipt) 'Package has no toolchain receipt.'
    }
    Invoke-Case 'complete-manifest' { & "$bundle\Install-CaelestiaRelease.ps1" -BundleRoot $bundle -VerifyOnly }
    # Only now import the package's maintenance implementation.
    . "$bundle\payload\Caelestia-InstallCommon.ps1"
    function New-CaelestiaLaunchTask { throw 'Package tests must never request a launch task.' }
    function Start-CaelestiaDetached { throw 'Package tests must never launch the shell.' }
    Assert-True ($null -ne (Get-CaelestiaIntegrationTestRoots)) 'Package lacks safe integration redirection.'
    $registry = (Get-CaelestiaIntegrationTestRoots).Registry
    $prefix = Join-Path $root 'app'
    $profile = Join-Path $root 'profile'
    Invoke-Case 'unsafe-release-paths' {
        foreach ($relative in @('../escape', 'payload/../escape', 'payload/CON.txt', 'payload/file.', 'payload/C:/escape')) {
            Assert-Refused { Resolve-ReleaseFile $bundle $relative } 'path'
        }
        Assert-True (-not (Test-Path $prefix) -and -not (Test-Path $profile)) 'Path refusals wrote install/profile.'
    }
    Invoke-Case 'reparse-refusal' {
        $target = Join-Path $root 'junction-target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $junction = Join-Path $bundle 'payload\junction'
        try {
            New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
            Assert-Refused { Test-ReleaseBundle $bundle } 'symlink or reparse'
            Assert-True (-not (Test-Path $prefix) -and -not (Test-Path $profile)) 'Reparse refusal wrote install/profile.'
        } finally {
            if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
        }
    }
    foreach ($mutation in @('tampered', 'partial', 'extra')) {
        Invoke-Case $mutation {
            $file = Join-Path $bundle 'payload\defaults\shell.json'
            $bytes = [IO.File]::ReadAllBytes($file)
            try {
                switch ($mutation) {
                    tampered { [IO.File]::WriteAllText($file, 'tampered') }
                    partial { [IO.File]::Delete($file) }
                    extra { [IO.File]::WriteAllText("$bundle\unexpected.txt", 'extra') }
                }
                Assert-Refused { Invoke-PackageInstall $bundle $prefix $profile } 'corrupt release file|unlisted files'
                Assert-True (-not (Test-Path $prefix) -and -not (Test-Path $profile)) 'Malformed package wrote install/profile.'
            } finally {
                [IO.File]::WriteAllBytes($file, $bytes)
                if (Test-Path "$bundle\unexpected.txt") { Remove-Item -LiteralPath "$bundle\unexpected.txt" }
            }
        }
    }
    foreach ($runtime in @('missing', 'outdated')) {
        Invoke-Case "runtime-$runtime" {
            Assert-Refused { Invoke-PackageInstall $bundle $prefix $profile -RuntimeFixture $runtime } 'Redistributable'
            Assert-True (-not (Test-Path $prefix) -and -not (Test-Path $profile)) 'Runtime refusal wrote install/profile.'
        }
    }
    Invoke-Case 'clean-install-and-relocation' {
        Invoke-PackageInstall $bundle $prefix $profile
        $record = Get-Selector $prefix
        $installed = Resolve-CaelestiaRuntimePrefix $prefix
        Assert-True ($record.current -and $record.profile -eq $profile) 'Invalid active metadata.'
        $qml = Get-Content -LiteralPath "$installed\shell\shell.qml" -Raw
        Assert-True ($qml.Contains($profile.Replace('\', '/') + '/data') -and -not $qml.Contains('@CAELESTIA_PROFILE@')) 'Profile relocation failed.'
        Assert-True ((Get-FileHash "$installed\release-manifest.json").Hash -eq $manifestHash) 'Installed manifest differs.'
        Assert-True (Test-Path (Get-CaelestiaIntegration $prefix).Shortcut) 'Redirected integration missing.'
    }
    New-Item -ItemType Directory -Path "$profile\config" -Force | Out-Null
    $config = Join-Path $profile 'config\package-test.txt'
    [IO.File]::WriteAllText($config, 'preserve this configuration')
    $configHash = (Get-FileHash $config).Hash
    Invoke-Case 'previous-package-update-and-configuration' {
        # With no historical ZIP, change only the installed version metadata.
        # Payload bytes remain those of the verified package, never an alleged
        # historical binary. This is transaction coverage, not compatibility.
        if ($PreviousPackage) {
            $previous = Expand-Package $PreviousPackage (Join-Path $root 'previous')
            $null = Test-ReleaseBundle $previous
            Assert-True ((Get-Content "$previous\payload\Caelestia-InstallCommon.ps1" -Raw).Contains('CAELESTIA_TEST_INTEGRATION_ROOT')) 'Previous package lacks integration confinement.'
            Invoke-PackageInstall $previous $prefix $profile
        } else {
            $installed = Resolve-CaelestiaRuntimePrefix $prefix
            $metadata = Get-Content "$installed\install.json" -Raw | ConvertFrom-Json
            $metadata.appVersion = '0.0.0'
            Write-CaelestiaJsonAtomic "$installed\install.json" $metadata
        }
        $script:previousId = (Get-Selector $prefix).current
        Invoke-PackageInstall $bundle $prefix $profile
        $record = Get-Selector $prefix
        Assert-True ($record.previous -eq $previousId -and $record.current -ne $previousId) 'Update did not retain previous selector.'
        Assert-Preserved
        $resultsContext = if ($PreviousPackage) { "Previous ZIP SHA256 $previousHash" } else { 'Synthesized older installed metadata 0.0.0; same verified payload bytes.' }
        [IO.File]::WriteAllText("$OutputRoot\previous-package.txt", $resultsContext)
    }
    Invoke-Case 'stopped-rollback' {
        $lock = Enter-CaelestiaInstallLock $prefix
        Assert-True ($null -ne $lock) 'Stopped rollback could not acquire lock.'
        try { Switch-CaelestiaVersion $prefix (Get-Selector $prefix).previous }
        finally { Exit-CaelestiaInstallLock $lock }
        Assert-True ((Get-Selector $prefix).current -eq $previousId) 'Rollback did not select prior version.'
        Assert-Preserved
    }
    Invoke-Case 'denied-write' {
        $before = [IO.File]::ReadAllText("$prefix\install.json")
        $held = [IO.File]::Open("$prefix\install.json", 'Open', 'Read', 'Read')
        try { Assert-Refused { Invoke-PackageInstall $bundle $prefix $profile } 'used by another process|access|sharing|read' }
        finally { $held.Dispose() }
        Assert-True ([IO.File]::ReadAllText("$prefix\install.json") -eq $before) 'Denied write changed selector.'
        Assert-Preserved
    }
    Invoke-Case 'failed-process-stop' {
        $before = (Get-Selector $prefix).current
        Assert-Refused {
            Invoke-PackageInstall $bundle $prefix $profile -Injection "function Stop-CaelestiaHosts { throw 'Injected process stop failure.' }"
        } 'Injected process stop failure'
        Assert-True ((Get-Selector $prefix).current -eq $before) 'Failed stop changed selector.'
        Assert-Preserved
    }
    Invoke-Case 'concurrent-operation' {
        $ready = [Threading.ManualResetEvent]::new($false)
        $release = [Threading.ManualResetEvent]::new($false)
        $worker = [powershell]::Create()
        $null = $worker.AddScript({
            param($common, $prefix, $ready, $release)
            . $common
            $lock = Enter-CaelestiaInstallLock $prefix
            try { if (-not $lock) { throw 'Fixture lock unavailable.' }; $ready.Set(); $release.WaitOne(30000) }
            finally { Exit-CaelestiaInstallLock $lock }
        }).AddArgument("$bundle\payload\Caelestia-InstallCommon.ps1").AddArgument($prefix).AddArgument($ready).AddArgument($release)
        $pending = $worker.BeginInvoke()
        try {
            Assert-True ($ready.WaitOne(10000)) 'Concurrent owner did not acquire lock.'
            $before = (Get-Selector $prefix).current
            Assert-Refused { Invoke-PackageInstall $bundle $prefix $profile } 'already in progress'
            Assert-True ((Get-Selector $prefix).current -eq $before) 'Concurrent install changed selector.'
        } finally {
            $null = $release.Set(); $null = $worker.EndInvoke($pending)
            $worker.Dispose(); $ready.Dispose(); $release.Dispose()
        }
    }
    Invoke-Case 'failed-integration-write' {
        $before = (Get-Selector $prefix).current
        Assert-Refused {
            Invoke-PackageInstall $bundle $prefix $profile -Injection "function New-CaelestiaShortcut { throw 'Injected integration write failure.' }"
        } 'Injected integration write failure'
        Assert-True ((Get-Selector $prefix).current -eq $before) 'Integration failure did not recover prior selector.'
        Assert-True (Test-Path (Get-CaelestiaIntegration $prefix).Shortcut) 'Prior integration was lost.'
        Assert-Preserved
    }
    Invoke-Case 'ownership-checked-purge-refusal' {
        $ownerFile = Join-Path $profile 'profile-owner.json'
        Assert-True (Test-Path -LiteralPath $ownerFile) 'Profile owner marker not found.'
        $ownerBytes = [IO.File]::ReadAllBytes($ownerFile)
        try {
            $owner = Get-Content $ownerFile -Raw | ConvertFrom-Json
            $owner.installId = 'foreign'
            Write-CaelestiaJsonAtomic $ownerFile $owner
            Assert-Refused { & "$prefix\Uninstall-Caelestia.ps1" -Prefix $prefix -Purge -NoDialogs } 'Refusing -Purge'
            Assert-True (Test-Path "$prefix\install.json") 'Foreign purge removed installation.'
            Assert-Preserved
        } finally { [IO.File]::WriteAllBytes($ownerFile, $ownerBytes) }
    }
    Invoke-Case 'uninstall-preserves-configuration' {
        & "$prefix\Uninstall-Caelestia.ps1" -Prefix $prefix -NoDialogs
        Assert-True (-not (Test-Path $prefix)) 'Uninstall left prefix.'
        Assert-Preserved
    }
    Invoke-Case 'owned-profile-purge' {
        Invoke-PackageInstall $bundle $prefix $profile
        & "$prefix\Uninstall-Caelestia.ps1" -Prefix $prefix -Purge -NoDialogs
        Assert-True (-not (Test-Path $prefix) -and -not (Test-Path $profile)) 'Owned purge left managed directories.'
    }
} finally {
    if ($registry -and (Test-Path -LiteralPath $registry)) {
        Assert-True ($registry -like 'HKCU:\Software\CaelestiaWindowsTests\*') 'Unsafe registry cleanup.'
        Remove-Item -LiteralPath $registry -Recurse -Force
    }
    $env:CAELESTIA_TEST_INTEGRATION_ROOT = $oldIntegration
    $env:QT_QPA_PLATFORM = $oldQtPlatform
    $safe = [IO.Path]::GetFullPath($root)
    Assert-True ((Split-Path -Parent $safe) -eq ([IO.Path]::GetTempPath().TrimEnd('\')) -and
        (Split-Path -Leaf $safe) -like 'cpl-*') 'Unsafe fixture cleanup.'
    # Trusted helper, including on a verification failure before package import.
    . (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
    Assert-CaelestiaNoReparsePoints $safe
    Remove-Item -LiteralPath $safe -Recurse -Force
}
