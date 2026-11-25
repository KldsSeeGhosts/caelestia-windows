[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows'),
    [string]$ProfileRoot,
    [switch]$Restart,
    [switch]$Autostart,
    [switch]$DesktopShortcut,
    [switch]$NoIntegration,
    [switch]$InstallPrerequisites,
    [switch]$NonInteractive,
    # Optional Python/CLI downloads are not part of the basic shell install.
    [switch]$PrepareSchemeRuntime,
    # Obtain this digest from trusted release metadata, not the extracted ZIP.
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
# Resolve in the body for Windows PowerShell -File, like the stable launcher.
if (-not $BundleRoot) { $BundleRoot = $PSScriptRoot }
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess -or
    $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Use 64-bit Windows PowerShell on Windows x64.'
}

# Bootstrap deliberately has no imports, dot-sources, native processes or
# supplied-code execution until the complete bundle passes validation.
function Assert-ReleaseComponents([string[]]$Parts) {
    foreach ($part in $Parts) {
        if (-not $part -or $part -in @('.', '..') -or
            $part.IndexOfAny([char[]]@(':', '"', '<', '>', '|', '?', '*', '\', '/')) -ge 0 -or
            $part -match '[\x00-\x1f\x7f]|[. ]$|^(?i:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[0-9\u00b9\u00b2\u00b3]|LPT[0-9\u00b9\u00b2\u00b3])(\.|$)') {
            throw 'Unsafe release path component.'
        }
    }
}

function Assert-ReleaseDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {
        throw 'Release, prefix and profile paths require local, non-root directories.'
    }
    Assert-ReleaseComponents $full.Substring(3).Split('\')
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Release paths must not traverse files, symlinks or reparse points.'
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $full
}

function Resolve-ReleaseFile([string]$Root, [string]$Relative) {
    if (-not $Relative -or $Relative.Contains('\') -or $Relative.StartsWith('/') -or
        $Relative.IndexOfAny([char[]]@(':', '"', '<', '>', '|', '?', '*')) -ge 0 -or
        $Relative -match '[\x00-\x1f\x7f]') { throw 'Invalid release manifest path.' }
    Assert-ReleaseComponents $Relative.Split('/')
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/', '\')))
    if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Release path escapes its root.' }
    return $full
}

function Test-ReleaseVCRuntimeVersions([int]$Installed, [string]$RegisteredVersion,
    [version[]]$FileVersions, [version]$MinimumVersion) {
    if ($Installed -ne 1 -or $RegisteredVersion -notmatch '^v?\d+\.\d+\.\d+\.\d+$' -or
        $FileVersions.Count -ne 3) { return $false }
    if ([version]($RegisteredVersion -replace '^v', '') -lt $MinimumVersion) { return $false }
    return @($FileVersions | Where-Object { $null -eq $_ -or $_ -lt $MinimumVersion }).Count -eq 0
}

function Test-ReleaseVCRuntime([version]$MinimumVersion) {
    $baseKey = $null
    $runtimeKey = $null
    try {
        # Read the native x64 registration, never PATH or a developer SDK.
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $runtimeKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')
        if (-not $runtimeKey) { return $false }
        $versions = foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            $file = Join-Path ([Environment]::SystemDirectory) $name
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($file)
            [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
        }
        return Test-ReleaseVCRuntimeVersions ([int]$runtimeKey.GetValue('Installed', 0)) `
            ([string]$runtimeKey.GetValue('Version', '')) $versions $MinimumVersion
    } catch { return $false }
    finally {
        if ($runtimeKey) { $runtimeKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Test-ReleaseMicrosoftSubject([string]$Subject) {
    return $Subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)'
}

function Test-ReleaseMicrosoftChain($Certificate) {
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromSeconds(30)
        if (-not $chain.Build($Certificate)) { return $false }
        $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
        return (Test-ReleaseMicrosoftSubject $root.Subject) -and
            $root.Subject -eq $root.Issuer -and
            $root.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -match
                '^Microsoft (?:RSA |ECC )?Root Certificate Authority(?: \d{4})?$'
    } finally { $chain.Dispose() }
}

function Assert-ReleaseVCRuntimeSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        -not (Test-ReleaseMicrosoftSubject $signature.SignerCertificate.Subject) -or
        -not (Test-ReleaseMicrosoftChain $signature.SignerCertificate)) {
        throw 'Runtime download must have a valid Microsoft Corporation signature and trusted Microsoft root chain.'
    }
}

function Confirm-ReleaseVCRuntimeInstall([switch]$Unattended) {
    if ($Unattended -or -not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or
        [Environment]::GetCommandLineArgs() -match '^-NonI(?:nteractive)?$') { return $false }
    $answer = Read-Host 'Install Microsoft Visual C++ x64 Redistributable? This downloads from Microsoft and requests administrator approval [y/N]'
    return $answer -match '^(?i:y|yes)$'
}

function New-ReleasePrivateStagingDirectory([string]$Kind) {
    $candidate = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-' + $Kind + '-' + [guid]::NewGuid().ToString('N'))
    # Even a short-lived download is a privileged-installer input. Deny
    # inheritance at directory creation. Only this user and SYSTEM can change
    # the tree; administrators receive read/execute so over-the-shoulder UAC
    # using a different administrator account can run the verified binary,
    # without receiving write or modify rights.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    $adminRule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance, [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($adminRule)
    $directory = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [IO.Directory]::CreateDirectory($candidate, $acl)
    } else {
        [IO.FileSystemAclExtensions]::CreateDirectory($acl, $candidate)
    }
    return $directory.FullName
}

# Keep the exact verified bytes open with no write sharing until the elevated
# installer process has finished reading them. This closes the replace-after-
# signature race without trusting the temporary path or ACL alone.
function Open-ReleaseVerifiedInstaller([string]$Path) {
    return [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Install-ReleaseVCRuntime($Prerequisite, [switch]$Consent, [switch]$Unattended) {
    $refusal = ('Microsoft Visual C++ x64 Redistributable 14.44.35211.0 or newer is required. ' +
        'Install or repair it using Microsoft''s official download, then rerun Install.cmd: ' +
        'https://aka.ms/vc14/vc_redist.x64.exe . The runtime installer may require administrator approval. ' +
        'Caelestia has not changed your installation.')
    $temporary = $null
    $verifiedStream = $null
    try {
        if ($Prerequisite.downloadUrl -cne 'https://aka.ms/vc14/vc_redist.x64.exe') {
            throw 'Unsupported runtime download URL.'
        }
        if (-not $Consent) {
            if (-not (Confirm-ReleaseVCRuntimeInstall -Unattended:$Unattended)) {
                throw 'Runtime installation declined or non-interactive. Use -InstallPrerequisites to consent without prompting.'
            }
        }
        $temporary = New-ReleasePrivateStagingDirectory 'vcredist'
        $download = Join-Path $temporary 'vc_redist.x64.exe'
        Invoke-WebRequest -Uri $Prerequisite.downloadUrl -OutFile $download -UseBasicParsing
        $verifiedStream = Open-ReleaseVerifiedInstaller $download
        Assert-ReleaseVCRuntimeSignature $download
        $process = Start-Process -FilePath $download -ArgumentList '/install', '/quiet', '/norestart' `
            -Verb RunAs -Wait -PassThru
        $exitCode = $process.ExitCode
        if ($exitCode -notin @(0, 3010, 1638)) { throw "Runtime installer exited with code $exitCode." }
        if ($exitCode -eq 3010) { Write-Warning 'Microsoft Visual C++ runtime installation requires a reboot. Restart Windows before using Caelestia.' }
        if (-not (Test-ReleaseVCRuntime ([version]$Prerequisite.minimumVersion))) {
            throw "Runtime still does not meet the minimum after installer exit code $exitCode."
        }
    } catch {
        throw ($refusal + ' ' + $_.Exception.Message)
    } finally {
        if ($verifiedStream) { $verifiedStream.Dispose() }
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

# Read-only PowerShell 7 discovery, mirroring the Visual C++ check: native x64
# MSI registration, the standard MSI destination, the supported per-user
# destination, App Paths and the verified Microsoft Store package. PATH and
# the current host are never trusted here; the bootstrap may itself be running
# on 5.1. These standalone helpers mirror the contract in
# Caelestia-InstallCommon.ps1 exactly; the file must run before any payload
# code is loaded.
function ConvertTo-ReleaseVersionOrNull([string]$Text) {
    if (-not $Text) { return $null }
    $clean = ($Text.Trim() -split '[-+]')[0]
    $parsed = $null
    if ([version]::TryParse($clean, [ref]$parsed)) { return $parsed }
    return $null
}

# The manifest's powershell7 prerequisite floor is parsed once, strictly: a
# plain 7.x.y(.z) numeric string that survives a direct [version] cast later.
# Suffixed forms like '7.4.0-preview.1' are rejected here rather than crashing
# an unchecked cast in the install body. The anchors are \A and \z, not ^ and
# $: in .NET regex, $ matches before a trailing \n, so '7.4.0\n' would slip
# through. minimumVersion must be a real string; a JSON array would cast to a
# string but still fail the pattern, so check the type first.
function Get-ReleasePowerShell7MinimumVersion($Prerequisite) {
    if ($null -eq $Prerequisite -or $Prerequisite.minimumVersion -isnot [string]) { return $null }
    $text = $Prerequisite.minimumVersion
    if ($text -cnotmatch '\A7\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\z') { return $null }
    $parsed = $null
    if (-not [version]::TryParse($text, [ref]$parsed)) { return $null }
    if ($parsed -lt [version]'7.4.0') { return $null }
    return $parsed
}

function Test-ReleaseNoReparse([string]$Path, [string]$Boundary) {
    # The file and every ancestor up to and including Boundary must be real.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $stop = Get-ReleaseLongPath $Boundary
    $ancestor = $Path
    while ($true) {
        $ancestor = Split-Path -Parent $ancestor
        if (-not $ancestor) { return $true }
        $node = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($node -and ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ([string]::Equals((Get-ReleaseLongPath $ancestor), $stop, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
}

function Test-ReleaseNoReparseDirectoryChain([string]$Directory, [string]$Boundary) {
    # Like Test-ReleaseNoReparse but the subject is a directory that may
    # legitimately be an AppExecLink parent; only ancestors are checked there.
    $item = Get-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
    if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $stop = Get-ReleaseLongPath $Boundary
    $ancestor = $Directory
    while ($true) {
        $ancestor = Split-Path -Parent $ancestor
        if (-not $ancestor) { return $true }
        $node = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($node -and ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ([string]::Equals((Get-ReleaseLongPath $ancestor), $stop, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
}

function Test-ReleaseX64Executable([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $reader = [IO.BinaryReader]::new($stream)
            # Validate the DOS signature before trusting the header offset.
            if ($stream.Length -lt 0x40 -or $reader.ReadUInt16() -ne 0x5A4D) { return $false }
            $stream.Seek(0x3C, [IO.SeekOrigin]::Begin) | Out-Null
            $offset = $reader.ReadInt32()
            if ($offset -lt 0x40 -or $offset -gt $stream.Length - 6) { return $false }
            $stream.Seek($offset, [IO.SeekOrigin]::Begin) | Out-Null
            if ($reader.ReadUInt32() -ne 0x00004550) { return $false }
            return $reader.ReadUInt16() -eq 0x8664
        } finally { $stream.Dispose() }
    } catch { return $false }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ReleaseReparseProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess,
        uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool DeviceIoControl(SafeFileHandle hDevice, uint dwIoControlCode,
        IntPtr inBuffer, uint nInBufferSize, byte[] outBuffer, uint nOutBufferSize,
        out uint bytesReturned, IntPtr overlapped);
}
'@ -IgnoreWarnings

function Get-ReleaseAppExecLinkFields([string]$Path) {
    # Read the reparse data behind a Microsoft Store execution alias. Returns
    # the three printed UTF-16 fields (PackageId, EntryPoint, TargetExePath)
    # or $null when the file is not a readable AppExecLink reparse point.
    $handle = [ReleaseReparseProbe]::CreateFileW($Path, 0, 7, [IntPtr]::Zero, 3, 0x00200000, [IntPtr]::Zero)
    try {
        if (-not $handle -or $handle.IsInvalid) { return $null }
        $buffer = New-Object byte[] 32768
        $returned = [uint32]0
        if (-not [ReleaseReparseProbe]::DeviceIoControl($handle, 0x000900A8, [IntPtr]::Zero, 0,
                $buffer, $buffer.Length, [ref]$returned, [IntPtr]::Zero)) { return $null }
        # IO_REPARSE_TAG_APPEXECLINK. The literal overflows int32 in Windows
        # PowerShell 5.1, so the cast uses a string constant.
        if ($returned -lt 12 -or [BitConverter]::ToUInt32($buffer, 0) -ne [uint32]'0x8000001B') { return $null }
        $dataLength = [BitConverter]::ToUInt16($buffer, 4)
        if ($dataLength -lt 4 -or 8 + $dataLength -gt $returned) { return $null }
        # Four NUL-terminated UTF-16 fields fill the reparse data: PackageId,
        # EntryPoint, TargetExePath, then a small integer string.
        $decoded = [Text.Encoding]::Unicode.GetString($buffer, 8, $dataLength)
        $fields = $decoded.Substring(2).Split("`0")
        if ($fields.Count -lt 4 -or $fields[3] -notmatch '^\d+$') { return $null }
        return , [string[]]@($fields[0], $fields[1], $fields[2])
    } catch { return $null }
    finally { if ($handle) { $handle.Dispose() } }
}

function Test-ReleasePowerShellCandidate([string]$Candidate, [string]$Boundary, [version]$MinimumVersion) {
    # One shared gate for every file-based candidate: exists, no reparse point
    # on the file or any ancestor up to the trusted root, PE x64, and a
    # product/file version at or above the floor. ProductVersion can carry a
    # "+sha" or "-preview" suffix; the numeric part is what compares.
    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $false }
    if (-not (Test-ReleaseNoReparse $Candidate $Boundary)) { return $false }
    if (-not (Test-ReleaseX64Executable $Candidate)) { return $false }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Candidate)
    $version = ConvertTo-ReleaseVersionOrNull $info.ProductVersion
    if (-not $version) { $version = ConvertTo-ReleaseVersionOrNull $info.FileVersion }
    return ($null -ne $version) -and ($version -ge $MinimumVersion)
}

function Get-ReleaseOsLocalAppData {
    # The OS LocalAppData, not $env:LOCALAPPDATA, which test fixtures and
    # worker environments redirect. Per-user installs and the Store alias
    # always live under the real user profile.
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localAppData) { $localAppData = $env:LOCALAPPDATA }
    return $localAppData
}

# Mirror of Get-CaelestiaLongPath for the standalone bootstrap: strip the
# Win32 long-path prefix, resolve to an absolute path, then resolve a real
# item's recorded FullName so an 8.3 spelling or differently cased drive
# compares equal to the install-location spelling.
function Get-ReleaseLongPath([string]$Path) {
    if (-not $Path) { return '' }
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $Path = '\\' + $Path.Substring(8) }
    elseif ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [StringComparison]::Ordinal)) { $Path = $Path.Substring(4) }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    if ($full -eq $root) { return $full }
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.FullName) {
            $full = $item.FullName
            if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
        }
    } catch { }
    return $full
}

function Test-ReleasePowerShell7Versions([bool]$Registered, [string[]]$CandidatePaths,
    [hashtable]$FileVersions, [version]$PackageVersion, [bool]$StoreAliasExists, [version]$MinimumVersion) {
    if ($Registered) { return $true }
    foreach ($path in $CandidatePaths) {
        $version = $FileVersions[$path]
        if ($null -ne $version -and $version -ge $MinimumVersion) { return $true }
    }
    return ($PackageVersion -ge $MinimumVersion) -and $StoreAliasExists
}

function Test-ReleasePowerShell7([version]$MinimumVersion) {
    $registered = $false
    $baseKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $installed = $baseKey.OpenSubKey('SOFTWARE\Microsoft\PowerShellCore\InstalledVersions')
        if ($installed) {
            try {
                foreach ($name in $installed.GetSubKeyNames()) {
                    $sub = $installed.OpenSubKey($name)
                    if (-not $sub) { continue }
                    try {
                        $location = [string]$sub.GetValue('InstallLocation')
                        $semantic = [string]$sub.GetValue('SemanticVersion')
                        $version = ConvertTo-ReleaseVersionOrNull $semantic
                        if (-not ($location -and $version -and $version -ge $MinimumVersion)) { continue }
                        $location = [IO.Path]::GetFullPath($location).TrimEnd('\')
                        # A registered location must still live under a trusted
                        # root: Program Files or the OS per-user Programs tree.
                        # The reparse boundary is the trusted root itself, so a
                        # reparse point on the per-user Programs directory or
                        # on OS LocalApplicationData is caught too.
                        $boundary = $null
                        $osLocal = Get-ReleaseOsLocalAppData
                        $programsRoot = [IO.Path]::GetFullPath((Join-Path $osLocal 'Programs')).TrimEnd('\')
                        $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
                        if ($location.Equals($programFilesRoot, [StringComparison]::OrdinalIgnoreCase) -or
                            $location.StartsWith($programFilesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            $boundary = $programFilesRoot
                        } elseif ($location.Equals($programsRoot, [StringComparison]::OrdinalIgnoreCase) -or
                            $location.StartsWith($programsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            $boundary = [IO.Path]::GetFullPath($osLocal).TrimEnd('\')
                        }
                        if (-not $boundary) { continue }
                        if (Test-ReleasePowerShellCandidate (Join-Path $location 'pwsh.exe') $boundary $MinimumVersion) {
                            $registered = $true
                            break
                        }
                    } finally { $sub.Dispose() }
                }
            } finally { $installed.Dispose() }
        }
    } catch { }
    finally { if ($baseKey) { $baseKey.Dispose() } }
    if ($registered) { return $true }
    $standard = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-ReleasePowerShellCandidate $standard $env:ProgramFiles $MinimumVersion) {
        return $true
    }
    $perUser = Join-Path (Get-ReleaseOsLocalAppData) 'Programs\PowerShell\7\pwsh.exe'
    if (Test-ReleasePowerShellCandidate $perUser (Get-ReleaseOsLocalAppData) $MinimumVersion) {
        return $true
    }
    try {
        $appPaths = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe' -ErrorAction Stop
        $appPath = [string]$appPaths.'(default)'
        if (-not $appPath) { $appPath = [string]$appPaths.Path }
        if ($appPath) {
            $appPath = $appPath.Trim('"')
            if ([IO.Path]::GetFileName($appPath) -ne 'pwsh.exe') { $appPath = Join-Path $appPath 'pwsh.exe' }
            $appPath = [IO.Path]::GetFullPath($appPath).TrimEnd('\')
            $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
            if ($appPath.StartsWith($programFilesRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
                (Test-ReleasePowerShellCandidate $appPath $programFilesRoot $MinimumVersion)) {
                return $true
            }
        }
    } catch { }
    try {
        $package = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop |
            Where-Object { $_.PackageFamilyName -ceq 'Microsoft.PowerShell_8wekyb3d8bbwe' -and
                $_.Architecture -eq 'X64' } | Select-Object -First 1
        $packageVersion = if ($package) { ConvertTo-ReleaseVersionOrNull ([string]$package.Version) } else { $null }
        if ($package -and $packageVersion -and $packageVersion -ge $MinimumVersion) {
            # The package's own InstallLocation pwsh.exe must be a real x64
            # image with no reparse points up to WindowsApps and a version at
            # the floor. The stable execution alias under OS LocalAppData is
            # itself an AppExecLink reparse point: verify its ancestors are
            # real, then read the reparse data to confirm it dispatches into
            # this exact package and InstallLocation binary.
            $installLocation = [string]$package.InstallLocation
            $packageExe = if ($installLocation) { Join-Path $installLocation 'pwsh.exe' } else { '' }
            $windowsAppsRoot = if ($installLocation) { Split-Path -Parent $installLocation } else { '' }
            $packageOk = $packageExe -and $windowsAppsRoot -and
                (Test-ReleasePowerShellCandidate $packageExe $windowsAppsRoot $MinimumVersion)
            $osLocal = Get-ReleaseOsLocalAppData
            $alias = Join-Path $osLocal 'Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe'
            $aliasParent = Split-Path -Parent $alias
            $aliasOk = ((Split-Path -Leaf $aliasParent) -ceq 'Microsoft.PowerShell_8wekyb3d8bbwe') -and
                (Test-Path -LiteralPath $alias -PathType Leaf) -and
                (Test-ReleaseNoReparseDirectoryChain $aliasParent $osLocal)
            if ($aliasOk) {
                $linkFields = Get-ReleaseAppExecLinkFields $alias
                $targetExe = if ($linkFields) { Get-ReleaseLongPath $linkFields[2] } else { '' }
                $expectedExe = if ($packageExe) { Get-ReleaseLongPath $packageExe } else { '' }
                $aliasOk = $null -ne $linkFields -and
                    $linkFields[0] -ceq 'Microsoft.PowerShell_8wekyb3d8bbwe' -and
                    $linkFields[1] -ceq 'Microsoft.PowerShell_8wekyb3d8bbwe!App' -and
                    $targetExe -and $expectedExe -and
                    [string]::Equals($targetExe, $expectedExe, [StringComparison]::OrdinalIgnoreCase)
            }
            if ($packageOk -and $aliasOk) { return $true }
        }
    } catch { }
    return $false
}

function Confirm-ReleasePowerShell7Install([switch]$Unattended) {
    if ($Unattended -or -not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or
        [Environment]::GetCommandLineArgs() -match '^-NonI(?:nteractive)?$') { return $false }
    $answer = Read-Host 'Install Microsoft PowerShell 7 x64? This downloads from GitHub and requests administrator approval [y/N]'
    return $answer -match '^(?i:y|yes)$'
}

function Install-ReleasePowerShell7($Prerequisite, [switch]$Consent, [switch]$Unattended) {
    $refusal = ('64-bit PowerShell ' + [string]$Prerequisite.minimumVersion +
        ' or newer is required. Install it with the official MSI (' +
        [string]$Prerequisite.downloadUrl +
        '), `winget install --id Microsoft.PowerShell --source winget`, or the Microsoft Store, then rerun Install.cmd. ' +
        'Caelestia has not changed your installation.')
    $temporary = $null
    $verifiedStream = $null
    try {
        if ($Prerequisite.downloadUrl -isnot [string] -or
            $Prerequisite.downloadUrl -cnotmatch '\Ahttps://github\.com/PowerShell/PowerShell/releases/download/v7\.[0-9]+\.[0-9]+/PowerShell-7\.[0-9]+\.[0-9]+-win-x64\.msi\z') {
            throw 'Unsupported PowerShell download URL.'
        }
        if (-not $Consent) {
            if (-not (Confirm-ReleasePowerShell7Install -Unattended:$Unattended)) {
                throw 'PowerShell 7 installation declined or non-interactive. Use -InstallPrerequisites to consent without prompting.'
            }
        }
        $temporary = New-ReleasePrivateStagingDirectory 'pwsh'
        $download = Join-Path $temporary 'PowerShell-win-x64.msi'
        Invoke-WebRequest -Uri $Prerequisite.downloadUrl -OutFile $download -UseBasicParsing
        $verifiedStream = Open-ReleaseVerifiedInstaller $download
        # Same Authenticode gate as the Visual C++ redistributable: a Microsoft
        # signature and a trusted Microsoft root, not only a readable file.
        $signature = Get-AuthenticodeSignature -LiteralPath $download
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            -not (Test-ReleaseMicrosoftSubject $signature.SignerCertificate.Subject) -or
            -not (Test-ReleaseMicrosoftChain $signature.SignerCertificate)) {
            throw 'PowerShell download must have a valid Microsoft Corporation signature and trusted Microsoft root chain.'
        }
        $msiArgs = if ($Unattended) { '/qn' } else { '/passive' }
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList '/i', ('"' + $download + '"'), $msiArgs, '/norestart' `
            -Verb RunAs -Wait -PassThru
        $exitCode = $process.ExitCode
        if ($exitCode -notin @(0, 3010)) { throw "PowerShell installer exited with code $exitCode." }
        if ($exitCode -eq 3010) { Write-Warning 'PowerShell 7 installation requires a reboot. Restart Windows before using Caelestia.' }
        if (-not (Test-ReleasePowerShell7 ([version]$Prerequisite.minimumVersion))) {
            throw "PowerShell still does not meet the minimum after installer exit code $exitCode."
        }
    } catch {
        throw ($refusal + ' ' + $_.Exception.Message)
    } finally {
        if ($verifiedStream) { $verifiedStream.Dispose() }
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}

# Pure-data validation. Kept verbatim in the standalone release bootstrap so
# no supplied bundle code is loaded before complete verification.
function Assert-CaelestiaCaptureRelease {
    param([Parameter(Mandatory)]$Capture, [Parameter(Mandatory)][string]$NativeSourceRevision,
        [Parameter(Mandatory)][string]$ExecutableSha256)
    if ($Capture.representation -cne 'in-tree' -or $Capture.path -cne 'windows/capture' -or
        $NativeSourceRevision -cnotmatch '^[a-f0-9]{40}$' -or
        $Capture.sourceRevision -cne $NativeSourceRevision -or
        $Capture.originRepository -cne 'https://github.com/KldsSeeGhosts/glazier.git' -or
        $Capture.originRevision -cne '37f795041cbbb32ed46cba103f3f000a3a99ac13' -or
        $Capture.cargoLockSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $Capture.executable -cne 'caelestia-capture.exe' -or
        $Capture.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $ExecutableSha256.ToLowerInvariant() -cne $Capture.sha256) {
        throw 'Invalid first-party capture release provenance.'
    }
}

function Test-ReleaseBundle([string]$Root, [string]$ExpectedHash = '') {
    $Root = Assert-ReleaseDirectory $Root
    # Enumerate manually, without following junctions even once. This also
    # rejects unlisted files (including hidden files), not just missing files.
    $actual = @{}
    $directories = @{}
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release contains a symlink or reparse point.' }
            $relative = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
            $null = Resolve-ReleaseFile $Root $relative
            if ($actual.ContainsKey($relative) -or $directories.ContainsKey($relative)) { throw 'Release contains case-colliding paths.' }
            if ($item.PSIsContainer) { $directories[$relative] = $true; $pending.Push($item.FullName) }
            else { $actual[$relative] = $item }
        }
    }
    if (-not $actual.ContainsKey('release.json')) { throw 'Missing release.json.' }
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $Root 'release.json') -Algorithm SHA256).Hash
    if ($ExpectedHash -and $manifestHash -ne $ExpectedHash) { throw 'Release manifest digest differs from trusted metadata.' }
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schema -ne 'caelestia-windows-release' -or $manifest.version -ne 1 -or
        $manifest.platform -ne 'windows-x64' -or $manifest.sourceRevision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.nativeSourceRevision -notmatch '^[a-f0-9]{40}$' -or $manifest.backendRevision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.releaseId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        $manifest.dependencies.quickshell.revision -ne $manifest.backendRevision -or
        $manifest.dependencies.m3shapes.revision -notmatch '^[a-f0-9]{40}$' -or
        $manifest.prerequisites.visualCppRuntime.deployment -ne 'system' -or
        $manifest.prerequisites.visualCppRuntime.architecture -ne 'x64' -or
        $manifest.prerequisites.visualCppRuntime.minimumVersion -ne '14.44.35211.0' -or
        $manifest.prerequisites.visualCppRuntime.downloadUrl -ne 'https://aka.ms/vc14/vc_redist.x64.exe' -or
        -not $manifest.files -or $manifest.relocation -ne 'profile-pragmas-v1') {
        throw 'Unsupported or incomplete release manifest.'
    }
    $firstPartyCapture = $null -ne $manifest.dependencies.PSObject.Properties['capture'] -and
        $null -ne $manifest.dependencies.capture
    $captureExecutable = if ($firstPartyCapture) { 'caelestia-capture.exe' } else { 'glazier.exe' }
    if (-not $firstPartyCapture -and $manifest.dependencies.glazier.revision -notmatch '^[a-f0-9]{40}$') {
        throw 'Missing capture release provenance.'
    }
    $listed = @{}
    $parents = @{}
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.path
        $path = Resolve-ReleaseFile $Root $relative
        # Supplier notice trees preserve upstream attribution paths, including
        # licenses from upstream tests. They are data, never runtime test wiring.
        $supplementalNotice = $relative.StartsWith('payload/licenses/supplemental/', [StringComparison]::Ordinal)
        if ($relative -eq 'release.json' -or $listed.ContainsKey($relative) -or
            (-not $relative.StartsWith('payload/', [StringComparison]::Ordinal) -and $relative -notin @('Install.cmd', 'Install-CaelestiaRelease.ps1', 'INSTALL-RELEASE.md')) -or
            $relative -match '(^|/)(\.git|\.zcode|screenshots?|evidence)(/|$)|\.pdb$|^payload/(install\.json|build\.json|versions|profile|config|runtime|logs?|cache|state|data)(/|$)' -or
            ($relative -match '(^|/)tests?(/|$)' -and -not $supplementalNotice) -or
            ($supplementalNotice -and [IO.Path]::GetExtension($relative) -in @('.exe', '.dll', '.pdb', '.zip', '.7z', '.tar', '.xz')) -or
            $relative -match '(^|/)((concrt|msvcp|msvcr|vccorlib|vcruntime)\d[^/]*\.dll|ucrtbase(?:d)?\.dll|api-ms-win-crt-[^/]*\.dll|vc_redist[^/]*\.exe)$' -or
            [string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            ($entry.size -isnot [long] -and $entry.size -isnot [int])) { throw 'Invalid or duplicate release file record.' }
        if (-not $actual.ContainsKey($relative) -or $actual[$relative].Length -ne $entry.size -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "Missing, partial or corrupt release file: $relative"
        }
        $listed[$relative] = $true
        $parent = $relative
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            $parents[$parent] = $true
        }
    }
    if ($actual.Count -ne $listed.Count + 1) { throw 'Release contains unlisted files.' }
    foreach ($directory in $directories.Keys) {
        if (-not $parents.ContainsKey($directory)) { throw 'Release contains an unlisted directory.' }
    }
    foreach ($required in @(
        'Install.cmd', 'Install-CaelestiaRelease.ps1', 'INSTALL-RELEASE.md',
        'payload/qs.exe', "payload/$captureExecutable", 'payload/qt.conf',
        'payload/Qt6Core.dll', 'payload/Qt6Qml.dll', 'payload/Qt6Quick.dll',
        'payload/plugins/platforms/qwindows.dll', 'payload/qml/Caelestia/Windows/qmldir',
        'payload/qml/M3Shapes/qmldir', 'payload/m3shapes.dll', 'payload/shell/shell.qml',
        'payload/shell/sources.json', 'payload/defaults/shell.json', 'payload/defaults/windows.json',
        'payload/defaults/keybinds.json', 'payload/DesktopTakeover.dll', 'payload/DesktopTakeover.build.json',
        'payload/Start-Caelestia.ps1', 'payload/Start-CaelestiaEntry.ps1',
        'payload/Manage-Caelestia.ps1', 'payload/Uninstall-Caelestia.ps1',
        'payload/Caelestia-InstallCommon.ps1', 'payload/Caelestia-Versions.ps1',
        'payload/Switch-CaelestiaToWindows.ps1', 'payload/Caelestia-Launcher.ps1',
        'payload/Start-DesktopShell.ps1', 'payload/Watch-DesktopShell.ps1', 'payload/Restore-Desktop.ps1',
        'payload/Install-SchemeRuntime.ps1', 'payload/Get-AccountPicture.ps1', 'payload/Banner-Suppression.ps1',
        'payload/scheme/requirements.lock.txt', 'payload/scheme/win_scheme.py', 'payload/scheme/fcntl.py',
        'payload/licenses/LICENSE', 'payload/licenses/THIRD-PARTY-NOTICES.md',
        'payload/licenses/sources.lock.json', 'payload/licenses/Glazier-LICENSE',
        'payload/licenses/Glazier-THIRD_PARTY_NOTICES.md', 'payload/licenses/M3Shapes-LICENSE',
        'payload/licenses/Quickshell-LICENSE', 'payload/licenses/Qt/LGPL-3.0.txt'
    )) {
        if (-not $listed.ContainsKey($required)) { throw "Incomplete release: $required" }
    }
    # Additive contract. Historical preview bundles remain verifiable, while
    # updater-enabled bundles cannot omit their root router dependencies.
    if ($manifest.PSObject.Properties['appVersion']) {
        if ($manifest.appVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
            $manifest.profileSchema -ne 1) { throw 'Unsupported app/profile version contract.' }
        foreach ($updateRequired in @('payload/version.json', 'payload/update-trust.json', 'payload/Caelestia-SemVer.ps1',
            'payload/Caelestia-Update.ps1', 'payload/Caelestia-UpdateTrust.ps1', 'payload/Caelestia-UpdateSecurity.cs')) {
            if (-not $listed.ContainsKey($updateRequired)) { throw "Incomplete release: $updateRequired" }
        }
    }
    # The runtime host contract is distinct from the updater appVersion
    # marker: pre-migration updater bundles already carried appVersion without
    # the powershell7 prerequisite or supervisor source. A manifest that
    # declares runtimeHost must declare the supported pwsh host exactly.
    $ps7Property = $null
    if ($null -ne $manifest.prerequisites) {
        $ps7Property = $manifest.prerequisites.PSObject.Properties['powershell7']
    }
    $hasPowerShell7Property = $null -ne $ps7Property
    # Assign directly rather than through an `if (...) { ... }` expression,
    # which enumerates the pipeline and unwraps a single-element JSON array.
    $ps7Raw = $null
    if ($hasPowerShell7Property) { $ps7Raw = $ps7Property.Value }
    $hasValidPowerShell7Object = $hasPowerShell7Property -and
        $null -ne $ps7Raw -and
        -not ($ps7Raw -is [Array]) -and
        $ps7Raw -is [pscustomobject]
    if ($manifest.PSObject.Properties['runtimeHost']) {
        # A JSON array value (for example runtimeHost: []) would slip past a
        # bare -cne because PowerShell compares each element and returns @(),
        # which is falsy, so the whole -cne test reads false. Pin the type.
        if ($manifest.runtimeHost -isnot [string] -or $manifest.runtimeHost -cne 'powershell7') {
            throw 'Unsupported release runtime host.'
        }
        if (-not $hasValidPowerShell7Object) {
            throw 'A powershell7 runtime host requires its prerequisite contract.'
        }
        # New-format releases compile the supervisor for the pwsh host, but
        # the installed payload can roll back or run on a host whose CLR
        # differs. Shipping the source keeps Import-CaelestiaDesktopTakeover
        # able to rebuild for the running runtime when the cached DLL does
        # not match.
        if (-not $listed.ContainsKey('payload/DesktopTakeover.cs')) {
            throw 'Incomplete release: payload/DesktopTakeover.cs'
        }
    }
    # Any bundle that declares a powershell7 prerequisite declares valid,
    # strictly parseable fields for it, and the runtime payload that consumes
    # them. This holds with or without the runtimeHost marker.
    # Explicit null or a JSON array of objects is rejected; only omitting the
    # property preserves the historical pre-migration path.
    $ps7Minimum = $null
    if ($hasPowerShell7Property) {
        if (-not $hasValidPowerShell7Object) {
            throw 'Invalid PowerShell 7 prerequisite contract.'
        }
        $ps7 = $ps7Raw
        if ($ps7.architecture -isnot [string] -or $ps7.architecture -cne 'x64' -or
            $ps7.deployment -isnot [string] -or $ps7.deployment -cne 'system' -or
            $null -eq ($ps7Minimum = Get-ReleasePowerShell7MinimumVersion $ps7) -or
            $ps7.downloadUrl -isnot [string] -or
            $ps7.downloadUrl -cnotmatch '\Ahttps://github\.com/PowerShell/PowerShell/releases/download/v7\.[0-9]+\.[0-9]+/PowerShell-7\.[0-9]+\.[0-9]+-win-x64\.msi\z') {
            throw 'Invalid PowerShell 7 prerequisite fields.'
        }
        if (-not $listed.ContainsKey('payload/DesktopTakeover.cs')) {
            throw 'Incomplete release: payload/DesktopTakeover.cs'
        }
    }
    if ($firstPartyCapture) {
        $capture = $manifest.dependencies.capture
        $captureHash = (Get-FileHash -LiteralPath (Join-Path $Root "payload\$captureExecutable") -Algorithm SHA256).Hash
        Assert-CaelestiaCaptureRelease $capture $manifest.nativeSourceRevision $captureHash
        if ($listed.ContainsKey('payload/glazier.exe') -or
            -not $listed.ContainsKey('payload/licenses/Caelestia-Capture-ORIGIN.md')) {
            throw 'First-party capture requires its origin notice and a single helper identity.'
        }
        # Read only already hash-verified JSON. Bootstrap executes no supplied
        # capture/maintenance code during provenance validation.
        $sourceLock = Get-Content -LiteralPath (Join-Path $Root 'payload\licenses\sources.lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $pin = $sourceLock.glazier
        if ($pin.representation -cne 'in-tree' -or $pin.sourceRevision -cne 'shell' -or
            $pin.path -cne $capture.path -or $pin.repository -cne $capture.originRepository -or
            $pin.originRevision -cne $capture.originRevision -or $pin.revision -cne $capture.originRevision -or
            $pin.cargoLockPath -cne 'windows/capture/Cargo.lock' -or
            $pin.cargoLockSha256 -cne $capture.cargoLockSha256 -or $pin.executable -cne $captureExecutable) {
            throw 'Capture release descriptor and bundled source lock disagree.'
        }
    }
    $header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    $shell = [IO.File]::ReadAllText((Join-Path $Root 'payload\shell\shell.qml'))
    if (-not $shell.StartsWith($header, [StringComparison]::Ordinal) -or
        [regex]::Matches($shell, '(?m)^//@ pragma (DataDir|StateDir|CacheDir) ').Count -ne 3) {
        throw 'Unexpected profile relocation template.'
    }
    return [pscustomobject]@{ Manifest = $manifest; Sha256 = $manifestHash; PowerShell7Minimum = $ps7Minimum }
}

$BundleRoot = Assert-ReleaseDirectory $BundleRoot
$verified = Test-ReleaseBundle $BundleRoot $ExpectedManifestSha256
$release = $verified.Manifest
$captureRelease = if ($release.dependencies.PSObject.Properties['capture']) { $release.dependencies.capture } else { $null }
$captureExecutable = if ($null -ne $captureRelease) { 'caelestia-capture.exe' } else { 'glazier.exe' }
$verifiedManifestHash = $verified.Sha256
if ((Get-FileHash -LiteralPath (Join-Path $BundleRoot 'release.json') -Algorithm SHA256).Hash -ne $verifiedManifestHash) {
    throw 'Release manifest changed during verification.'
}
if ($VerifyOnly) { $release; return }
# The bundle is fully verified at this point, so its shared installer library
# is trusted. Elevation is refused before prerequisite downloads or any per-user
# state is touched; VerifyOnly remains a data-only diagnostic on elevated hosts.
$payloadSource = Join-Path $BundleRoot 'payload'
. (Join-Path $payloadSource 'Caelestia-InstallCommon.ps1')
Assert-CaelestiaInstallerNotElevated
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    throw 'Installation requires Windows 11 x64. VerifyOnly is data-only and is not installation acceptance.'
}
if (-not (Test-ReleaseVCRuntime ([version]$release.prerequisites.visualCppRuntime.minimumVersion))) {
    Install-ReleaseVCRuntime $release.prerequisites.visualCppRuntime `
        -Consent:$InstallPrerequisites -Unattended:$NonInteractive
}
$powerShell7Minimum = $verified.PowerShell7Minimum
if ($null -ne $powerShell7Minimum) {
    if (-not (Test-ReleasePowerShell7 $powerShell7Minimum)) {
        Install-ReleasePowerShell7 $release.prerequisites.powershell7 `
            -Consent:$InstallPrerequisites -Unattended:$NonInteractive
    }
    # Record the verified floor for the payload's runtime discovery,
    # provisioning, launch and dispatch so a future release that raises the
    # manifest floor is honored everywhere instead of a hardcoded 7.4.0.
    $env:CAELESTIA_MIN_POWERSHELL_VERSION = $powerShell7Minimum.ToString()
}
# Supplied maintenance code was loaded immediately after verification above.
$Prefix = Assert-ReleaseDirectory (Resolve-CaelestiaDirectory $Prefix)
if (-not $ProfileRoot) {
    $ProfileRoot = if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) {
        [string](Read-CaelestiaInstall $Prefix).profile
    } else { Join-Path $env:LOCALAPPDATA 'caelestia-windows' }
}
$ProfileRoot = Assert-ReleaseDirectory (Resolve-CaelestiaDirectory $ProfileRoot)
foreach ($pair in @(@($Prefix, $ProfileRoot), @($Prefix, $BundleRoot), @($ProfileRoot, $BundleRoot))) {
    $left = Get-CaelestiaLongPath $pair[0]
    $right = Get-CaelestiaLongPath $pair[1]
    if ([string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase) -or
        $left.StartsWith($right + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $right.StartsWith($left + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Prefix, profile and extracted release must be separate, non-nested directories.'
    }
}
if ($NoIntegration -and $Autostart) { throw '-NoIntegration cannot register autostart.' }
if ($NoIntegration -and $DesktopShortcut) { throw '-NoIntegration cannot create a desktop shortcut.' }
$lock = Enter-CaelestiaInstallLock $Prefix
$payload = "$Prefix.staging-$PID"
try {
    if (-not $lock) { throw 'An installation or rollback is already in progress.' }
    # Release installs never Force-adopt a foreign profile or unowned prefix.
    # Reject links in existing managed trees before any recovery or cleanup.
    foreach ($tree in @($Prefix, $ProfileRoot, "$Prefix.old")) {
        if (Test-Path -LiteralPath $tree) {
            $null = Resolve-CaelestiaDirectory $tree
            Assert-CaelestiaNoReparsePoints $tree
        }
    }
    $context = Initialize-CaelestiaInstall $Prefix $ProfileRoot -Restart:$Restart
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Prefix) | Out-Null
    New-Item -ItemType Directory -Path $payload | Out-Null
    [ordered]@{ product = 'caelestia-windows'; prefix = $Prefix; pid = $PID } |
        ConvertTo-Json | Set-Content -LiteralPath "$payload\.caelestia-staging.json" -Encoding UTF8
    foreach ($entry in $release.files) {
        if (-not $entry.path.StartsWith('payload/', [StringComparison]::Ordinal)) { continue }
        $relative = $entry.path.Substring(8)
        $target = Resolve-ReleaseFile $payload $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        [IO.File]::Copy((Resolve-ReleaseFile $BundleRoot $entry.path), $target)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw 'Release changed during copying; activation was refused.'
        }
    }
    $shellPath = Join-Path $payload 'shell\shell.qml'
    $shell = [IO.File]::ReadAllText($shellPath)
    # Only the three exact, verified header lines are transformed. Retain the
    # original manifest plus explicit destination hashes, never skip a hash.
    $header = "//@ pragma DataDir @CAELESTIA_PROFILE@/data`n//@ pragma StateDir @CAELESTIA_PROFILE@/state`n//@ pragma CacheDir @CAELESTIA_PROFILE@/cache`n"
    $profileQml = $ProfileRoot.Replace('\', '/')
    $replacement = "//@ pragma DataDir $profileQml/data`n//@ pragma StateDir $profileQml/state`n//@ pragma CacheDir $profileQml/cache`n"
    [IO.File]::WriteAllText($shellPath, ($replacement + $shell.Substring($header.Length)), [Text.UTF8Encoding]::new($false))
    $shellHash = (Get-FileHash -LiteralPath $shellPath -Algorithm SHA256).Hash
    $sourcesPath = Join-Path $payload 'shell\sources.json'
    $sources = Get-Content -LiteralPath $sourcesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $shellEntries = @($sources | Where-Object { $_.staged -eq 'shell.qml' })
    if ($shellEntries.Count -ne 1) { throw 'Invalid production staging record.' }
    $shellEntries[0].stagedSha256 = $shellHash
    $sources | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sourcesPath -Encoding UTF8
    [IO.File]::Copy((Join-Path $BundleRoot 'release.json'), (Join-Path $payload 'release-manifest.json'))
    if ((Get-FileHash -LiteralPath "$payload\release-manifest.json" -Algorithm SHA256).Hash -ne $verifiedManifestHash) {
        throw 'Release manifest changed during copying.'
    }
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $Prefix; profile = $ProfileRoot
        installId = $context.InstallId; sourceRevision = $release.sourceRevision
        backendRevision = $release.backendRevision
        glazierRevision = $(if ($captureRelease) { $captureRelease.originRevision } else { $release.dependencies.glazier.revision })
        captureSourcePath = $(if ($captureRelease) { $captureRelease.path } else { '' })
        captureSourceRevision = $(if ($captureRelease) { $captureRelease.sourceRevision } else { '' })
        captureOriginRevision = $(if ($captureRelease) { $captureRelease.originRevision } else { '' })
        captureCargoLockSha256 = $(if ($captureRelease) { $captureRelease.cargoLockSha256 } else { '' })
        captureExecutable = $captureExecutable
        captureSha256 = $(if ($captureRelease) { (Get-FileHash -LiteralPath "$payload\$captureExecutable" -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' })
        executableSha256 = (Get-FileHash -LiteralPath "$payload\qs.exe" -Algorithm SHA256).Hash
        glazierSha256 = (Get-FileHash -LiteralPath "$payload\$captureExecutable" -Algorithm SHA256).Hash
        releaseId = $release.releaseId
        appVersion = $release.appVersion
        profileSchema = $release.profileSchema
        releaseManifestSha256 = (Get-FileHash -LiteralPath "$payload\release-manifest.json" -Algorithm SHA256).Hash
        relocatedShellSha256 = $shellHash
        relocatedSourcesSha256 = (Get-FileHash -LiteralPath $sourcesPath -Algorithm SHA256).Hash
        powerShellMinimumVersion = $(if ($null -ne $powerShell7Minimum) { $powerShell7Minimum.ToString() } else { '' })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$payload\install.json" -Encoding UTF8
    Remove-Item -LiteralPath "$payload\.caelestia-staging.json"
    Write-CaelestiaProfileOwner $ProfileRoot $Prefix $context.InstallId $context.ProfileExclusive
    if ($PrepareSchemeRuntime) {
        $scheme = Install-CaelestiaSchemeRuntime $payload $ProfileRoot
        if (-not $scheme.available) { Write-Warning 'Optional scheme runtime unavailable; the shell will use its fixed palette.' }
    }
    $runtime = Install-CaelestiaVersion $Prefix $payload -Restart:$Restart -Autostart:$Autostart -NoIntegration:$NoIntegration
    Remove-CaelestiaSchemeGenerations $Prefix $ProfileRoot
    $installed = Read-CaelestiaInstall $Prefix
    if (-not $NoIntegration) {
        Complete-CaelestiaInstallIntegration $Prefix $runtime -Previous ([string]$installed.previous) `
            -Restart:$Restart -Autostart:$Autostart -DesktopShortcut:$DesktopShortcut
    }
    Remove-CaelestiaRetiredVersions $Prefix
    Write-Output "Installed release $($release.releaseId): $Prefix"
    Write-Output ('Start: pwsh -NoProfile -File "' + (Join-Path $Prefix 'Start-Caelestia.ps1') + '" -PreparedSchemeRuntime')
    if (-not $NoIntegration) {
        $integration = Get-CaelestiaIntegration $Prefix
        if ($integration.Shortcut) {
            Write-Output "Start menu: $(Split-Path -Leaf $integration.Shortcut) (starts without a terminal)"
        }
        if ($integration.SwitchBackShortcut) {
            Write-Output "Switch back: $(Split-Path -Leaf $integration.SwitchBackShortcut)"
        }
        Write-Output 'Uninstall: Settings > Apps > Installed apps > Caelestia for Windows'
    }
    Write-Output "Profile preserved: $ProfileRoot"
} finally {
    try {
        if ($lock -and (Test-Path -LiteralPath $payload)) {
            $safe = Resolve-CaelestiaDirectory $payload
            if ($safe -ne "$Prefix.staging-$PID") { throw 'Unsafe release staging cleanup.' }
            Assert-CaelestiaNoReparsePoints $safe
            Remove-Item -LiteralPath $safe -Recurse -Force
        }
    } finally {
        Exit-CaelestiaInstallLock $lock
    }
}
