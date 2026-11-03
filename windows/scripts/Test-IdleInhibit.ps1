[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [ValidateRange(15, 120)][int]$TimeoutSeconds = 30,
    # Keep the isolated run directory after a pass too.
    [switch]$Keep
)
# Offscreen check for windows/shell/adapters/daemons/IdleInhibit.qml. Stages
# the production graph, verifies the daemon drives the backend's native
# IdleInhibitor and starts no process, then toggles the RuntimeState contract
# through the native request twice. It never reads the live profile, installs
# anything or operates a live shell.
#
# Exit code is 0 on pass and 1 on failure.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix)
$run = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-idleinhibit-' + [guid]::NewGuid().ToString('N'))
$profile = Join-Path $run 'profile'
$logRoot = Join-Path $run 'logs'
$passed = $false
$failure = ''
$assertions = 0
$exitCode = $null
$output = ''
$timedOut = $false
$elapsed = [Diagnostics.Stopwatch]::StartNew()

try {
    $exe = Join-Path $BuildRoot 'quickshell\qs.exe'
    $qmlRoot = Join-Path $BuildRoot 'install\qml'
    foreach ($path in @($exe, (Join-Path $QtPrefix 'bin\qtpaths.exe'),
        (Join-Path $QtPrefix 'plugins\platforms\qoffscreen.dll'),
        (Join-Path $qmlRoot 'Caelestia\State\qmldir'),
        (Join-Path $qmlRoot 'Caelestia\Windows\qmldir'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing headless prerequisite: $path"
        }
    }

    New-Item -ItemType Directory -Force -Path $run, $profile, $logRoot,
        (Join-Path $run 'temp'), (Join-Path $run 'appdata'), (Join-Path $run 'localappdata') | Out-Null
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
    }

    $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') `
        -ProfileRoot $profile -Prototype shell-live
    $stage = [IO.Path]::GetFullPath($stage)
    $adapterPath = Join-Path $stage 'daemons\IdleInhibit.qml'
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw "The production stage did not map the idle-inhibit daemon: $adapterPath"
    }
    $adapterText = [IO.File]::ReadAllText($adapterPath)
    if ($adapterText -notmatch 'import Quickshell\.Wayland') {
        throw 'The staged idle-inhibit daemon does not import the native backend module.'
    }
    if ($adapterText -notmatch 'IdleInhibitor\s*\{' -or $adapterText -notmatch 'enabled:\s*root\.active') {
        throw 'The staged idle-inhibit daemon does not drive the native request through the Live gate.'
    }
    if ($adapterText -match '\bProcess\s*\{' -or $adapterText -match 'powershell|KeepAwake\.ps1|Start-Sleep') {
        throw 'The staged idle-inhibit daemon still launches or polls the PowerShell helper.'
    }
    if (Test-Path -LiteralPath (Join-Path $stage 'helpers\KeepAwake.ps1')) {
        throw 'The production stage still contains helpers/KeepAwake.ps1.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\sources.json') -Raw | ConvertFrom-Json
    if (@($manifest.PSObject.Properties.Name) -match 'KeepAwake') {
        throw 'The production staging map still references KeepAwake.ps1.'
    }

    # Path pragmas isolate Quickshell storage only. Qt bootstrap and every
    # native gate are supplied through ProcessStartInfo before Process.Start.
    $header = @("//@ pragma DataDir $profile\data", "//@ pragma StateDir $profile\state",
        "//@ pragma CacheDir $profile\cache")
    $testSource = Get-Content -LiteralPath "$repoRoot\windows\tests\IdleInhibitTest.qml" -Raw
    [IO.File]::WriteAllText((Join-Path $stage 'idle-inhibit-test.qml'),
        (($header -join "`n") + "`n" + $testSource), (New-Object Text.UTF8Encoding($false)))

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '--no-color --log-times --path "' + (Join-Path $stage 'idle-inhibit-test.qml') + '"'
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $environment = $info.EnvironmentVariables
    foreach ($name in @($environment.Keys)) {
        if ($name -like 'CAELESTIA_*' -or $name -like 'QS_*' -or
            $name -in @('QT_QPA_PLATFORM', 'QT_QUICK_BACKEND', 'QSG_RHI_BACKEND', 'QML_IMPORT_PATH',
                'QML2_IMPORT_PATH', 'QML_DISK_CACHE_PATH', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME',
                'XDG_DATA_HOME', 'XDG_CACHE_HOME')) {
            $environment.Remove($name)
        }
    }
    $values = [ordered]@{
        'PATH' = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
        'QML_IMPORT_PATH' = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        'QML2_IMPORT_PATH' = "$stage\imports;$qmlRoot;$QtPrefix\qml"
        'QML_DISK_CACHE_PATH' = "$profile\cache"
        'CAELESTIA_CONFIG_DIR' = "$profile\config"
        'CAELESTIA_STATE_DIR' = "$profile\state"
        'CAELESTIA_CACHE_DIR' = "$profile\cache"
        'CAELESTIA_RUNTIME_DIR' = "$profile\runtime"
        'CAELESTIA_PROFILE_ROOT' = $profile
        'QS_RUNTIME_DIR' = "$profile\runtime"
        'XDG_CONFIG_HOME' = "$profile\config"
        'XDG_STATE_HOME' = "$profile\state"
        'XDG_DATA_HOME' = "$profile\data"
        'XDG_CACHE_HOME' = "$profile\cache"
        'LOCALAPPDATA' = "$run\localappdata"
        'APPDATA' = "$run\appdata"
        'TEMP' = "$run\temp"
        'TMP' = "$run\temp"
        'QS_DISABLE_CRASH_HANDLER' = '1'
        'QS_WINDOWS_TRAY_HOOK' = '0'
        'QS_WINDOWS_BLUR' = '0'
        'QT_QPA_PLATFORM' = 'offscreen'
        'QT_QUICK_BACKEND' = 'software'
        'QT_LOGGING_RULES' = 'quickshell.windows.*.debug=false;quickshell.windows.*.info=false'
        'CAELESTIA_COMBINED_LIVE' = '1'
        'CAELESTIA_SHELL_LIVE' = '0'
    }
    foreach ($name in $values.Keys) { $environment[$name] = [string]$values[$name] }

    $process = [Diagnostics.Process]::Start($info)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $logRoot 'stdout.log'), $stdout)
    [IO.File]::WriteAllText((Join-Path $logRoot 'stderr.log'), $stderr)
    $output = "$stdout`n$stderr"
    $exitCode = $process.ExitCode

    $match = [regex]::Match($output, 'CAELESTIA_IDLEINHIBIT_PASS ([0-9]+)')
    if ($match.Success) { $assertions = [int]$match.Groups[1].Value }
    $diagnostics = $output -match 'TypeError|ReferenceError|SyntaxError|binding loop|Cannot assign|is not a type|is not installed|Failed to load component|No such file'

    if ($timedOut) {
        $failure = "timed out after $TimeoutSeconds s"
    } elseif ($exitCode -ne 0) {
        $failure = "qs.exe exited with code $exitCode"
    } elseif ($output -match 'CAELESTIA_IDLEINHIBIT_FAIL') {
        $failure = 'the adapter fixture reported a failed assertion'
    } elseif (-not $match.Success) {
        $failure = 'the adapter fixture did not report CAELESTIA_IDLEINHIBIT_PASS'
    } elseif ($diagnostics) {
        $failure = 'the adapter fixture logged a QML/runtime diagnostic'
    } else {
        $passed = $true
    }
} catch {
    $failure = $_.Exception.Message
}

$elapsed.Stop()
if ($passed) {
    Write-Output ("PASS Test-IdleInhibit: {0} assertions, native request toggled twice offscreen in {1:N1} s." -f $assertions, $elapsed.Elapsed.TotalSeconds)
    if (-not $Keep) {
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

Write-Output "FAIL Test-IdleInhibit: $failure"
if ($output) { Write-Output $output }
Write-Output "Run directory kept: $run"
exit 1
