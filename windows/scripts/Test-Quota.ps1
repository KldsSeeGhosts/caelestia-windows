[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    [ValidateSet('configured', 'offline', 'unconfigured')]
    [string[]]$Modes = @('configured', 'offline', 'unconfigured')
)
# Offscreen CPA quota smoke. Stages the production graph, then runs
# windows/quota/QuotaSmoke.qml in three isolated profiles:
#
#   configured    a synthetic local CPA stub feeds cpa_usage.py; the drawer opens
#                 with two providers, live meters and a screenshot;
#   offline       the CPA endpoint refuses connections; the service must settle
#                 into one saved-data error without hanging;
#   unconfigured  no cpa-agents.json exists; nothing spawns and the drawer stays
#                 disabled.
#
# It never contacts a real CPA or upstream provider, uses no credentials, takes
# no pointer input and never touches the live desktop.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $env:TEMP 'caelestia-quota-smoke' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot (Join-Path $run 'stage-profile') -Prototype shell-live
Copy-Item -LiteralPath "$repoRoot\windows\quota\QuotaSmoke.qml" -Destination "$stage\quota-smoke.qml"

$python = (& py -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1)
if (-not $python -or -not (Test-Path -LiteralPath $python)) {
    $python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
}
if (-not $python) { throw 'Python is required for the quota smoke.' }
$python = [IO.Path]::GetFullPath($python)
$stubScript = Join-Path $repoRoot 'windows\quota\fixtures\stub_cpa.py'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
foreach ($required in @($exe, "$qmlRoot\Caelestia\Config\qmldir", "$qmlRoot\Caelestia\Windows\qmldir", $stubScript)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing quota smoke prerequisite: $required" }
}

$offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
# The banner helper belongs to the host install, not this isolated stage. Its
# missing-settings warning is unrelated to the quota graph.
$hostOnly = 'Caelestia banner settings could not be read'
function Get-Diagnostics([string]$Body) {
    @($Body -split "`n" |
        Where-Object { $_ -match '^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b' } |
        Where-Object { $_ -notmatch $offscreenOnly -and $_ -notmatch $hostOnly })
}

# Windows PowerShell 5.1's -Encoding UTF8 writes a BOM, which Python's JSON
# reader rejects. Write the profile files without one.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Start-Stub([string]$Root) {
    $portFile = Join-Path $Root 'stub-port.txt'
    $stubOut = Join-Path $Root 'stub-stdout.log'
    $stubErr = Join-Path $Root 'stub-stderr.log'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $python
    # Windows PowerShell 5.1 has no ProcessStartInfo.ArgumentList; quote the
    # two paths explicitly instead.
    $info.Arguments = '"{0}" --port 0 --port-file "{1}"' -f $stubScript, $portFile
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $portFile); $i++) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $portFile)) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        throw "CPA stub did not start: $($errTask.GetAwaiter().GetResult())"
    }
    $port = (Get-Content -LiteralPath $portFile -Raw).Trim()
    return [pscustomobject]@{
        Process = $process; Port = $port; BaseUrl = "http://127.0.0.1:$port"
        Stdout = $stubOut; Stderr = $stubErr
    }
}

function Invoke-QuotaSmoke([string]$Mode) {
    $modeRoot = Join-Path $run $Mode
    $profile = Join-Path $modeRoot 'profile'
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
    }
    # Keep the bar wrapper's Loader inactive; the quota drawer is the subject.
    Write-Utf8NoBom "$profile\config\shell.json" '{"bar":{"persistent":false}}'

    $stub = $null
    $baseUrl = ''
    try {
        if ($Mode -eq 'configured') {
            $stub = Start-Stub $modeRoot
            $baseUrl = $stub.BaseUrl
        } elseif ($Mode -eq 'offline') {
            # Port 9 is discard; a local connection is refused immediately.
            $baseUrl = 'http://127.0.0.1:9'
        }
        if ($Mode -ne 'unconfigured') {
            Write-Utf8NoBom "$profile\config\quota.json" '{"enabled":true,"refreshIntervalMs":600000,"refreshTimeoutMs":5000}'
            $configJson = [ordered]@{ baseUrl = $baseUrl; adminKey = 'smoke-placeholder' } | ConvertTo-Json
            Write-Utf8NoBom "$profile\config\cpa-agents.json" $configJson
        }

        $screenshot = Join-Path $modeRoot 'quota.png'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $exe
        $info.Arguments = '--no-color --log-times --path "' + "$stage\quota-smoke.qml" + '"'
        $info.WorkingDirectory = $stage
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
        $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        $info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
        $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
        $info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
        $info.EnvironmentVariables['CAELESTIA_CACHE_DIR'] = "$profile\cache"
        $info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
        $info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profile
        $info.EnvironmentVariables['XDG_CONFIG_HOME'] = "$profile\config"
        $info.EnvironmentVariables['XDG_STATE_HOME'] = "$profile\state"
        $info.EnvironmentVariables['XDG_CACHE_HOME'] = "$profile\cache"
        $info.EnvironmentVariables['XDG_DATA_HOME'] = "$profile\data"
        $info.EnvironmentVariables['CAELESTIA_QUOTA_PYTHON'] = $python
        $info.EnvironmentVariables['CAELESTIA_QUOTA_SMOKE_MODE'] = $Mode
        $info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = '1'
        $info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = '0'
        $info.EnvironmentVariables['CAELESTIA_SHELL_SCALE'] = 'native'
        $info.EnvironmentVariables['CAELESTIA_SHELL_SCREENSHOT'] = ([Uri]$screenshot).AbsoluteUri
        $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
        $info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
        $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
        $info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
        foreach ($variable in @($info.EnvironmentVariables.Keys |
                Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' -or $_ -in @('CAELESTIA_COMBINED_LIVE', 'CAELESTIA_TRAY_FIXTURE', 'CAELESTIA_SHELL_LIVE') })) {
            $info.EnvironmentVariables.Remove($variable)
        }

        $process = [Diagnostics.Process]::Start($info)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit(90000)
        if ($timedOut) { $process.Kill(); $process.WaitForExit() }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $stdoutPath = Join-Path $modeRoot 'stdout.log'
        $stderrPath = Join-Path $modeRoot 'stderr.log'
        $stdout | Set-Content -LiteralPath $stdoutPath -Encoding UTF8
        $stderr | Set-Content -LiteralPath $stderrPath -Encoding UTF8
        $text = "$stdout`n$stderr"
        $diagnostics = Get-Diagnostics $text
        $passed = -not $timedOut -and $process.ExitCode -eq 0 -and
            $text.Contains("CAELESTIA_QUOTA_SMOKE_PASS $Mode") -and
            $diagnostics.Count -eq 0

        $records = @(Get-ChildItem -LiteralPath "$profile\state\omarchy\agents\usage" -Filter '*.json' -File -ErrorAction SilentlyContinue)
        if ($Mode -eq 'configured') {
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_RECORDS .*"status":"ok"' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_RECORDS .*"providers":2' -and
                $text -match '"codexLimits":2' -and $text -match '"claudeLimits":2' -and
                (Test-Path -LiteralPath $screenshot) -and (Get-Item -LiteralPath $screenshot).Length -gt 0 -and
                $records.Count -ge 2
        } elseif ($Mode -eq 'offline') {
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_OFFLINE .*"status":"error"' -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_OPEN .*"meters":0' -and
                $records.Count -eq 0
        } elseif ($Mode -eq 'unconfigured') {
            $passed = $passed -and
                $text -match 'CAELESTIA_QUOTA_SMOKE_UNCONFIGURED .*"configured":false' -and
                $text -match '"enabled":false' -and
                $records.Count -eq 0
        }

        return [ordered]@{
            mode = $Mode
            passed = $passed
            timedOut = $timedOut
            exitCode = $process.ExitCode
            diagnostics = $diagnostics
            profile = $profile
            records = $records.Count
            screenshot = $screenshot
            stdout = $stdoutPath
            stderr = $stderrPath
            baseUrl = $baseUrl
        }
    } finally {
        if ($stub -and -not $stub.Process.HasExited) {
            $stub.Process.Kill()
            $stub.Process.WaitForExit()
        }
    }
}

$results = @()
foreach ($mode in $Modes) {
    $result = Invoke-QuotaSmoke $mode
    $results += $result
    $result | ConvertTo-Json -Depth 6
    if (-not $result.passed) {
        Write-Host "Quota smoke failed: $mode ($($result.stdout))" -ForegroundColor Red
    }
}

$passed = ($results | Where-Object { -not $_.passed }).Count -eq 0
$summary = [ordered]@{
    passed = $passed
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    python = $python
    stage = $stage
    run = $run
    modes = $results
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$summary | ConvertTo-Json -Depth 8
if (-not $passed) { throw "Quota smoke failed: $run" }
