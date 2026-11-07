# Source and receipt interface shared by build, tests, install and release.
# The glazier lock key and build fields are one-release origin aliases only.
function Get-CaelestiaCaptureSource {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $lock = Get-Content -LiteralPath "$RepoRoot\windows\sources.lock.json" -Raw | ConvertFrom-Json
    $pin = $lock.glazier
    if ($pin.representation -cne 'in-tree' -or $pin.sourceRevision -cne 'shell' -or
        $pin.path -cne 'windows/capture' -or $pin.cargoLockPath -cne 'windows/capture/Cargo.lock' -or
        $pin.executable -cne 'caelestia-capture.exe' -or
        $pin.originRevision -cne '37f795041cbbb32ed46cba103f3f000a3a99ac13' -or
        $pin.revision -cne $pin.originRevision -or $pin.cargoLockSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Invalid in-tree capture source contract.'
    }
    $hash = (Get-FileHash -LiteralPath (Join-Path $RepoRoot $pin.cargoLockPath) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -cne $pin.cargoLockSha256) { throw 'Capture Cargo.lock does not match the source lock.' }
    $revision = & git -C $RepoRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $revision -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot resolve capture shell source revision.' }
    return [pscustomobject]@{
        path = Join-Path $RepoRoot $pin.path
        relativePath = $pin.path
        sourceRevision = $revision.Trim()
        originRepository = $pin.repository
        originRevision = $pin.originRevision
        cargoLockSha256 = $hash
        executable = $pin.executable
    }
}

function Assert-CaelestiaCaptureBuild {
    param([Parameter(Mandatory)]$Build, [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$Executable)
    if ($Build.captureBundled -ne $true -or $Build.captureSourcePath -cne $Source.relativePath -or
        $Build.captureSourceRevision -cne $Build.sourceRevision -or
        $Build.captureOriginRevision -cne $Source.originRevision -or
        $Build.captureCargoLockSha256 -cne $Source.cargoLockSha256 -or
        $Build.captureExecutable -cne $Source.executable -or
        $Build.captureSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'An exact first-party capture build receipt is required; rebuild the payload.'
    }
    if ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Build.captureSha256) {
        throw 'The staged caelestia-capture.exe does not match the capture build receipt.'
    }
}

function Test-CaelestiaCaptureNativeInput {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '^plugin/|^cmake/|^\.github/|^windows/(capture/|deps/|ci/|scripts/|tests/|release/|sources\.lock\.json$|toolchain[/.])|\.(rs|cpp|hpp|h|c|cc|cmake|qrc)$|(^|/)(CMakeLists\.txt|Cargo\.toml|Cargo\.lock)$') {
        return $true
    }
    # The former negative regex was too narrow for CI reuse: unknown files
    # silently became "QML-only". Only already-declared production shell
    # QML/JS/assets may override a native build. Do not grow a second path list.
    if ($Path -cmatch '\\|(^|/)\.\.?(/|$)' -or
        $Path -cnotmatch '\.(qml|js|png|svg|gif|webp|ttf|otf)$') { return $true }
    $map = Get-Content -LiteralPath "$PSScriptRoot\..\shell\sources.json" -Raw | ConvertFrom-Json
    return $Path -cnotin @($map.PSObject.Properties.Name)
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
