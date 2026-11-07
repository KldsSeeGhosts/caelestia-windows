[CmdletBinding()]
param(
    # Fresh directory outside the checkout for the verified executable.
    [Parameter(Mandatory)][string]$ToolDirectory,
    # Object cache. CI restores it only from trusted main-push saves.
    [Parameter(Mandatory)][string]$CacheDirectory,
    # Optional local copy of the pinned archive; it is verified the same way.
    [string]$Archive,
    [string]$Pin = (Join-Path $PSScriptRoot 'compiler-cache.json'),
    [string]$EnvironmentFile = $env:GITHUB_ENV
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$ToolDirectory = [IO.Path]::GetFullPath($ToolDirectory).TrimEnd('\')
$CacheDirectory = [IO.Path]::GetFullPath($CacheDirectory).TrimEnd('\')
foreach ($path in @($ToolDirectory, $CacheDirectory)) {
    if ($path -eq $repoRoot -or $path.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $repoRoot.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Compiler-cache directories must stay outside the source checkout.'
    }
}
if (Test-Path -LiteralPath $ToolDirectory) { throw 'The compiler-cache tool directory must be fresh.' }
$spec = Get-Content -LiteralPath $Pin -Raw | ConvertFrom-Json
if ($spec.schemaVersion -ne 1 -or $spec.tool -cne 'ccache' -or $spec.version -notmatch '^\d+\.\d+(\.\d+)?$' -or
    $spec.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $spec.file -notmatch '^[A-Za-z0-9._-]+\.zip$' -or
    $spec.url -cne "https://github.com/ccache/ccache/releases/download/v$($spec.version)/$($spec.file)" -or
    $spec.executable -cne "$([IO.Path]::GetFileNameWithoutExtension($spec.file))/ccache.exe" -or
    $spec.maxSize -notmatch '^\d+G$') {
    throw 'Invalid compiler-cache pin.'
}
New-Item -ItemType Directory -Path $ToolDirectory | Out-Null
if (-not $Archive) {
    $Archive = Join-Path $ToolDirectory $spec.file
    & curl.exe -L --fail --silent --show-error --connect-timeout 30 --max-time 300 `
        --retry 2 --retry-delay 2 $spec.url -o $Archive
    if ($LASTEXITCODE -ne 0) { throw 'Pinned ccache download failed. Check public network access; do not add credentials.' }
}
# .NET hashing avoids depending on the caller's PowerShell module path.
$stream = [IO.File]::OpenRead($Archive)
$sha = [Security.Cryptography.SHA256]::Create()
try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose(); $stream.Dispose() }
if ($actual -cne $spec.sha256) { throw 'Pinned ccache archive checksum mismatch; refusing to enable a compiler cache.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$executable = Join-Path $ToolDirectory 'ccache.exe'
$zip = [IO.Compression.ZipFile]::OpenRead($Archive)
try {
    $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $spec.executable })
    if ($entries.Count -ne 1) { throw 'The verified ccache archive does not contain exactly one pinned executable.' }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $executable)
} finally { $zip.Dispose() }
$version = @(& $executable --version)
if ($LASTEXITCODE -ne 0 -or $version[0] -cne "ccache version $($spec.version)") {
    throw 'The extracted ccache does not report the pinned version.'
}
New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
# Read no user, system or restored-cache configuration file. Every setting
# that affects reuse is explicit: compiler identity is its binary content,
# and arguments, sources and every included header are hashed (no sloppiness).
$config = Join-Path $ToolDirectory 'ccache.conf'
Set-Content -LiteralPath $config -Value '' -Encoding ASCII
$settings = [ordered]@{
    CCACHE_CONFIGPATH = $config
    CCACHE_DIR = $CacheDirectory
    CCACHE_COMPILERCHECK = 'content'
    CCACHE_MAXSIZE = $spec.maxSize
    CMAKE_C_COMPILER_LAUNCHER = $executable
    CMAKE_CXX_COMPILER_LAUNCHER = $executable
}
foreach ($name in $settings.Keys) { [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process') }
& $executable --zero-stats | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'ccache could not initialize its statistics.' }
if ($EnvironmentFile) {
    @($settings.Keys | ForEach-Object { "$_=$($settings[$_])" }) | Add-Content -LiteralPath $EnvironmentFile -Encoding UTF8
}
Write-Output "Verified ccache $($spec.version) enabled for later CMake configures. Cache: $CacheDirectory"
