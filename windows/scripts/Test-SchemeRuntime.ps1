[CmdletBinding()]
param(
    # Profile that holds a provisioned scheme runtime. Empty checks the
    # environment, then the documented install profile.
    [string]$ProfileRoot = ''
)

# The combined launcher remains usable with its fixed palette when the optional
# wallpaper-scheme Python runtime has not been installed. When a provisioned
# runtime is available, also exercise the warm worker and its downscaled input
# path with that exact interpreter.
$ErrorActionPreference = 'Stop'
$hostPython = ''
foreach ($name in @('py', 'python')) {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    # Windows' Store alias is not an installed interpreter.
    if (-not $command -or $command.Source -like '*\Microsoft\WindowsApps\*') { continue }
    try {
        $arguments = @('-c', 'import sys; print(sys.executable)')
        if ($name -eq 'py') { $arguments = @('-3') + $arguments }
        $interpreter = & $command.Source @arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $interpreter -and (Test-Path -LiteralPath "$interpreter" -PathType Leaf)) {
            $hostPython = "$interpreter"
            break
        }
    } catch {
        # A launcher without an installed interpreter also takes the fallback.
    }
}

# The provisioned runtime is generation-scoped; runtime.json publishes the
# verified interpreter for the active generation.
if ($env:CAELESTIA_SCHEME_PYTHON -and (Test-Path -LiteralPath $env:CAELESTIA_SCHEME_PYTHON -PathType Leaf)) {
    $runtimePython = $env:CAELESTIA_SCHEME_PYTHON
} else {
    $candidateRoots = @()
    if ($ProfileRoot) { $candidateRoots += $ProfileRoot }
    if ($env:CAELESTIA_PROFILE_ROOT) { $candidateRoots += $env:CAELESTIA_PROFILE_ROOT }
    if ($env:LOCALAPPDATA) { $candidateRoots += (Join-Path $env:LOCALAPPDATA 'caelestia-windows') }
    $runtimePython = ''
    foreach ($candidate in $candidateRoots) {
        $candidateJson = Join-Path $candidate 'scheme\runtime.json'
        if (-not (Test-Path -LiteralPath $candidateJson -PathType Leaf)) { continue }
        try {
            $record = Get-Content -LiteralPath $candidateJson -Raw | ConvertFrom-Json
            if ($record.available -and $record.python -and (Test-Path -LiteralPath $record.python -PathType Leaf)) {
                $runtimePython = "$($record.python)"
                break
            }
        } catch { }
    }
}

$warmWorkerTested = $false
$summary = 'Python 3 is unavailable; Caelestia keeps its fixed palette.'
if ($hostPython) { $summary = 'Python 3 is available; no provisioned scheme runtime was found.' }

if ($runtimePython) {
    $helper = Join-Path $PSScriptRoot 'scheme\win_scheme.py'
    $tests = Join-Path $PSScriptRoot 'scheme\test_win_scheme.py'
    # -B keeps the published generation free of new __pycache__ files.
    $null = & $runtimePython -B -c 'import PIL, materialyoucolor, caelestia.utils.scheme' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        Write-Warning 'The provisioned scheme runtime cannot import its generator modules; warm-worker tests were skipped.'
    } else {
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-scheme-runtime-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
        $previousProfile = $env:CAELESTIA_PROFILE_ROOT
        try {
            # The tests create their own profile; this keeps a live profile out
            # of the child environment even if it leaked through.
            $env:CAELESTIA_PROFILE_ROOT = Join-Path $stage 'profile'
            # Capture both streams as text: Windows PowerShell otherwise turns
            # native stderr records (unittest output, upstream warnings) into
            # error objects. The exit code is the verdict.
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $runtimePython
            $info.Arguments = '-B "' + $tests + '" -v'
            $info.WorkingDirectory = $stage
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($info)
            $outTask = $process.StandardOutput.ReadToEndAsync()
            $errTask = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) {
                try { $process.Kill() } catch { }
                throw 'Warm scheme-worker tests timed out.'
            }
            $testExit = $process.ExitCode
            Write-Host $outTask.GetAwaiter().GetResult()
            Write-Host $errTask.GetAwaiter().GetResult()
            if ($testExit -ne 0) { throw 'Warm scheme-worker tests failed.' }
            $warmWorkerTested = $true
            $summary = 'The provisioned scheme runtime passed the warm-worker and downscale tests.'
        } finally {
            $env:CAELESTIA_PROFILE_ROOT = $previousProfile
            $safeStage = [IO.Path]::GetFullPath($stage).TrimEnd('\')
            if ((Split-Path -Parent $safeStage) -eq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and
                (Split-Path -Leaf $safeStage) -like 'caelestia-scheme-runtime-*') {
                Remove-Item -LiteralPath $safeStage -Recurse -Force
            }
        }
    }
}

if (-not $hostPython -and -not $runtimePython) {
    Write-Warning 'Python 3 (py/python) is missing or unavailable. Dynamic colour generation is unavailable; Caelestia will use the fixed palette. Install Python 3 before using wallpaper-derived schemes.'
}
$reportedPython = if ($runtimePython) { $runtimePython } else { $hostPython }
[pscustomobject]@{
    available = [bool]($hostPython -or $runtimePython)
    python = $reportedPython
    fallback = [bool](-not ($hostPython -or $runtimePython))
    warmWorkerTested = $warmWorkerTested
    summary = $summary
}
