[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot
)
# Isolated payloads, profiles and stubs only. Never invoke an installed Glazier,
# capture a screen or touch the real shell payload.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$run = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-glazier-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$qs = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$stub = Join-Path $run 'stub.exe'
Add-Type -Path "$repo\windows\glazier\GlazierStub.cs" -OutputAssembly $stub -OutputType WindowsApplication
$hostStub = Join-Path $run 'host-stub.exe'
Add-Type -Path "$repo\windows\glazier\GlazierHostStub.cs" -OutputAssembly $hostStub -OutputType WindowsApplication
$windowStub = Join-Path $run 'window-stub.exe'
Add-Type -Path "$repo\windows\glazier\GlazierWindowStub.cs" -OutputAssembly $windowStub -OutputType WindowsApplication

function New-Case([string]$Name) {
    $root = Join-Path $run $Name
    $payload = Join-Path $root 'payload'
    $profile = Join-Path $root 'profile'
    $local = Join-Path $root 'local'
    foreach ($dir in @("$profile\config", "$profile\state", "$profile\runtime", "$profile\cache", "$profile\data")) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination "$payload\stage" -ProfileRoot $profile -Prototype shell-live
    # Take the three Glazier chords with inert native binds so the merge does
    # not register physical hotkeys during offscreen tests.
    [IO.File]::WriteAllText((Join-Path $root 'smoke-keybinds.json'),
        '{"binds":[{"keys":"PrintScreen","action":"native","name":"smoke-printscreen"},' +
        '{"keys":"Win+Shift+S","action":"native","name":"smoke-win-shift-s"},' +
        '{"keys":"Win+Shift+R","action":"native","name":"smoke-win-shift-r"}]}',
        (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Root = $root; Payload = $payload; Profile = $profile; Local = $local; Stage = $stage
        Bundled = Join-Path $payload 'glazier.exe'
        Override = Join-Path $root 'custom path\glazier.exe'
        Default = Join-Path $local 'Programs\Glazier\glazier.exe'
        Config = Join-Path $profile 'config\glazier.json'
        StubOutput = Join-Path $root 'invocation.txt'
        Marker = Join-Path $root 'hidden.txt'
        HostOutput = Join-Path $root 'host.txt'
        ProbeOutput = Join-Path $root 'probe.txt'
        Keybinds = Join-Path $root 'smoke-keybinds.json'
    }
}

function Invoke-Fixture($Case, [string]$Fixture, [hashtable]$Values) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $qs
    $info.Arguments = '--no-color --path "' + (Join-Path $Case.Stage $Fixture) + '"'
    $info.WorkingDirectory = $Case.Root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_*' -or $_ -like 'QS_*' -or $_ -like 'GLAZIER_*' })) {
        $info.EnvironmentVariables.Remove($name)
    }
    $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$($Case.Stage)\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$($Case.Stage)\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
    $info.EnvironmentVariables['LOCALAPPDATA'] = $Case.Local
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $Case.Profile 'config'
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_KEYBINDS'] = $Case.Keybinds
    $info.EnvironmentVariables['CAELESTIA_SHELL_LIVE'] = '0'
    $info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = '0'
    $info.EnvironmentVariables['GLAZIER_PAYLOAD_ROOT'] = $Case.Payload
    $info.EnvironmentVariables['GLAZIER_STUB_OUTPUT'] = $Case.StubOutput
    foreach ($key in $Values.Keys) { $info.EnvironmentVariables[$key] = [string]$Values[$key] }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(25000)) {
        $process.Kill()
        throw "$($Case.Root) fixture timed out"
    }
    $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $Case.Root 'run.log'), $text)
    if ($process.ExitCode -ne 0 -or $text -notmatch '(GLAZIER_TEST_PASS|GLAZIER_HOST_PASS)' -or
            $text -match '(?m)^\s*(WARN scene|ERROR|FATAL|CRITICAL)\b') {
        throw "$($Case.Root) failed: $text"
    }
    return $text
}

function Get-Lines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }
    # The unary comma keeps a one-line file an array in the caller.
    return ,@(Get-Content -LiteralPath $Path)
}

function Same-Path([string]$Actual, [string]$Expected) {
    return [string]::Equals($Actual.Trim(), $Expected.Trim(), [StringComparison]::OrdinalIgnoreCase)
}

function Set-Config($Case, [string]$Path) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Case.Config, (@{ executable = $Path } | ConvertTo-Json -Compress),
        (New-Object Text.UTF8Encoding($false)))
}

function Add-HostFixture($Case) {
    # Keep the staged profile routing: a fixture run directly with --path does
    # not inherit the pragmas from shell.qml.
    $pragmas = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $Case.Stage 'shell.qml')),
        '(?m)^//@ pragma (?:DataDir|StateDir|CacheDir) [^\r\n]+') | ForEach-Object { $_.Value })
    if ($pragmas.Count -ne 3) { throw 'Expected all three staged profile-directory pragmas.' }
    $fixture = [IO.File]::ReadAllText("$repo\windows\glazier\GlazierHostSmoke.qml")
    [IO.File]::WriteAllText((Join-Path $Case.Stage 'glazier-host-smoke.qml'),
        (($pragmas -join "`n") + "`n" + $fixture), (New-Object Text.UTF8Encoding($false)))
}

function Start-WindowHost([string]$Exe, [string]$Closed, [string]$PidFile) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['GLAZIER_WINDOW_CLOSED'] = $Closed
    $info.EnvironmentVariables['GLAZIER_WINDOW_PID'] = $PidFile
    return [Diagnostics.Process]::Start($info)
}

function Wait-WindowHost([string]$PidFile) {
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path -LiteralPath $PidFile) {
            $id = 0
            if ([int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(), [ref]$id) -and
                (Get-Process -Id $id -ErrorAction SilentlyContinue)) { return }
        }
        Start-Sleep -Milliseconds 50
    }
    throw "The window stub did not create its host window: $PidFile"
}

function Stop-WindowHost([string]$PidFile) {
    if (-not (Test-Path -LiteralPath $PidFile)) { return }
    $id = [int](Get-Content -LiteralPath $PidFile -Raw).Trim()
    $process = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $process) { return }
    & taskkill.exe /PID $id 2>&1 | Out-Null
    if (-not $process.WaitForExit(5000)) { throw "The window stub did not exit: $id" }
}

# --- executable resolution -------------------------------------------------
$resolution = @(
    [pscustomobject]@{ name = 'bundled'; bundled = $true; configured = $false; config = $false; default = $false; expected = 'bundled' },
    [pscustomobject]@{ name = 'bundled-first'; bundled = $true; configured = $true; config = $true; default = $false; expected = 'bundled' },
    [pscustomobject]@{ name = 'config-fallback'; bundled = $false; configured = $true; config = $true; default = $false; expected = 'override' },
    [pscustomobject]@{ name = 'missing'; bundled = $false; configured = $false; config = $false; default = $false; expected = '' },
    [pscustomobject]@{ name = 'default-ignored'; bundled = $false; configured = $false; config = $false; default = $true; expected = '' }
)
foreach ($mode in $resolution) {
    $case = New-Case $mode.name
    if ($mode.bundled) {
        New-Item -ItemType Directory -Force -Path (Split-Path $case.Bundled) | Out-Null
        Copy-Item $stub $case.Bundled
    }
    if ($mode.configured) {
        New-Item -ItemType Directory -Force -Path (Split-Path $case.Override) | Out-Null
        Copy-Item $stub $case.Override
    }
    if ($mode.config) { Set-Config $case $case.Override }
    if ($mode.default) {
        New-Item -ItemType Directory -Force -Path (Split-Path $case.Default) | Out-Null
        Copy-Item $stub $case.Default
    }
    $expected = switch ($mode.expected) {
        'bundled' { $case.Bundled }
        'override' { $case.Override }
        default { '' }
    }
    Copy-Item "$repo\windows\glazier\GlazierSmoke.qml" (Join-Path $case.Stage 'glazier-smoke.qml')
    $text = Invoke-Fixture $case 'glazier-smoke.qml' @{ GLAZIER_EXPECTED_PATH = $expected }
    $lines = Get-Lines $case.StubOutput
    if ($expected) {
        # exe, --no-hotkeys, --theme-file, <tokens>, --capture: a command can cold-start the host.
        if ($lines.Count -ne 5 -or -not (Same-Path $lines[0] $expected) -or $lines[1] -ne '--no-hotkeys' -or
                $lines[2] -ne '--theme-file' -or $lines[4] -ne '--capture') {
            throw "$($mode.name) launched the wrong command."
        }
    } elseif ($lines.Count -ne 0) {
        throw "$($mode.name) launched a process."
    }
    Write-Host "$($mode.name) resolved as expected"
}

# --- dismissal and hotkey routes -------------------------------------------
foreach ($route in @('launcher', 'shortcut', 'record', 'recordAction', 'ipc', 'timeout')) {
    $case = New-Case $route
    New-Item -ItemType Directory -Force -Path (Split-Path $case.Bundled) | Out-Null
    Copy-Item $stub $case.Bundled
    Copy-Item "$repo\windows\glazier\DismissSmoke.qml" (Join-Path $case.Stage 'glazier-smoke.qml')
    Copy-Item "$repo\windows\glazier\OffscreenShortcut.qml" (Join-Path $case.Stage 'components\misc\CustomShortcut.qml') -Force
    Copy-Item "$repo\windows\glazier\OffscreenAppList.qml" (Join-Path $case.Stage 'modules\launcher\AppList.qml') -Force
    $values = @{
        GLAZIER_DISMISS_MARKER = $case.Marker
        GLAZIER_ROUTE = $route
        GLAZIER_QS = $qs
        GLAZIER_HIDDEN_TIMEOUT = '600'
    }
    $null = Invoke-Fixture $case 'glazier-smoke.qml' $values
    $lines = Get-Lines $case.StubOutput
    if ($route -eq 'timeout') {
        if ($lines.Count -ne 0) { throw 'The dismissal timeout captured anyway.' }
    } else {
        $expected = if ($route -in @('record', 'recordAction')) { '--record' } else { '--capture' }
        if ($lines.Count -ne 6 -or -not (Same-Path $lines[0] $case.Bundled) -or $lines[1] -ne '--no-hotkeys' -or
                $lines[2] -ne '--theme-file' -or $lines[4] -ne $expected -or $lines[5] -ne 'hidden') {
            throw "$route launched the wrong command or before the surfaces reported hidden."
        }
    }
    Write-Host "$route passed"
}

# --- startup launch and arguments ------------------------------------------
function Assert-HostInvocation($Case, [string]$Theme) {
    $hostLines = Get-Lines $Case.HostOutput
    if ($hostLines.Count -ne 4 -or -not (Same-Path $hostLines[0] $Case.Bundled) -or
            $hostLines[1] -ne '--no-hotkeys' -or $hostLines[2] -ne '--theme-file' -or
            $hostLines[3].Replace('\', '/') -ne $Theme) {
        throw 'The tray host did not receive --no-hotkeys and the theme tokens.'
    }
}

foreach ($mode in @('host', 'host-running')) {
    $case = New-Case $mode
    New-Item -ItemType Directory -Force -Path (Split-Path $case.Bundled) | Out-Null
    Copy-Item $hostStub $case.Bundled
    Add-HostFixture $case
    $values = @{
        CAELESTIA_SHELL_LIVE = '1'
        GLAZIER_HOST_OUTPUT = $case.HostOutput
        GLAZIER_PROBE_OUTPUT = $case.ProbeOutput
        GLAZIER_EXPECTED_THEME = (Join-Path $case.Profile 'state\caelestia\theme-tokens.json').Replace('\', '/')
    }
    if ($mode -eq 'host-running') { $values.GLAZIER_STUB_RUNNING = '1' }
    $null = Invoke-Fixture $case 'glazier-host-smoke.qml' $values
    $hostLines = Get-Lines $case.HostOutput
    $probeLines = Get-Lines $case.ProbeOutput
    if ($mode -eq 'host-running') {
        if ($hostLines.Count -ne 0) { throw 'An already-running host was started again.' }
        if ($probeLines.Count -lt 1) { throw 'The running host was not observed.' }
    } else {
        Assert-HostInvocation $case $values.GLAZIER_EXPECTED_THEME
    }
    Write-Host "$mode passed"
}

# A standalone host is identified by its window's image path, asked to exit
# through WM_CLOSE and replaced by the bundled one. It is never killed and its
# install is untouched.
$case = New-Case 'host-replace'
New-Item -ItemType Directory -Force -Path (Split-Path $case.Bundled) | Out-Null
Copy-Item $windowStub $case.Bundled
$standalone = Join-Path $case.Root 'standalone'
New-Item -ItemType Directory -Force -Path $standalone | Out-Null
$standaloneExe = Join-Path $standalone 'glazier.exe'
Copy-Item $windowStub $standaloneExe
$standalonePid = Join-Path $case.Root 'standalone-pid.txt'
$standaloneClosed = Join-Path $case.Root 'standalone-closed.txt'
$standaloneProcess = Start-WindowHost $standaloneExe $standaloneClosed $standalonePid
$bundledPid = Join-Path $case.Root 'bundled-pid.txt'
$bundledClosed = Join-Path $case.Root 'bundled-closed.txt'
try {
    Wait-WindowHost $standalonePid
    Add-HostFixture $case
    $theme = (Join-Path $case.Profile 'state\caelestia\theme-tokens.json').Replace('\', '/')
    $text = Invoke-Fixture $case 'glazier-host-smoke.qml' @{
        CAELESTIA_SHELL_LIVE = '1'
        GLAZIER_HOST_OUTPUT = $case.HostOutput
        GLAZIER_PROBE_OUTPUT = $case.ProbeOutput
        GLAZIER_EXPECTED_THEME = $theme
        GLAZIER_WINDOW_PID = $bundledPid
        GLAZIER_WINDOW_CLOSED = $bundledClosed
    }
    if (([regex]::Matches($text, 'CAELESTIA_GLAZIER_HOST replacing a host that was not started from this payload')).Count -ne 1) {
        throw 'The standalone host replacement did not log exactly one path-free notice.'
    }
    if ($text -match [regex]::Escape($standalone)) {
        throw 'The replacement notice leaked the standalone install path.'
    }
    if (-not (Test-Path -LiteralPath $standaloneClosed)) {
        throw 'The standalone host did not receive a graceful close.'
    }
    if (-not $standaloneProcess.WaitForExit(5000)) {
        throw 'The standalone host did not exit after its close request.'
    }
    Assert-HostInvocation $case $theme
} finally {
    Stop-WindowHost $bundledPid
    if (-not $standaloneProcess.HasExited) {
        Stop-Process -Id $standaloneProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $standaloneProcess.Dispose()
}
Write-Host 'host-replace passed'

# A host already running from this payload is adopted, not restarted, and the
# shell's quit path stops it without starting a second host.
$case = New-Case 'host-adopt'
New-Item -ItemType Directory -Force -Path (Split-Path $case.Bundled) | Out-Null
Copy-Item $windowStub $case.Bundled
$adoptedPid = Join-Path $case.Root 'adopted-pid.txt'
$adoptedClosed = Join-Path $case.Root 'adopted-closed.txt'
$adoptedProcess = Start-WindowHost $case.Bundled $adoptedClosed $adoptedPid
try {
    Wait-WindowHost $adoptedPid
    Add-HostFixture $case
    $null = Invoke-Fixture $case 'glazier-host-smoke.qml' @{
        CAELESTIA_SHELL_LIVE = '1'
        GLAZIER_HOST_OUTPUT = $case.HostOutput
        GLAZIER_EXPECT_ADOPT = '1'
        GLAZIER_EXPECTED_THEME = (Join-Path $case.Profile 'state\caelestia\theme-tokens.json').Replace('\', '/')
    }
    if (Test-Path -LiteralPath $case.HostOutput) { throw 'An adopted host was started again.' }
    if (-not $adoptedProcess.WaitForExit(5000)) {
        throw 'The adopted host was not stopped when the shell exited.'
    }
    if (-not (Test-Path -LiteralPath $adoptedClosed)) {
        throw 'The adopted host was not stopped gracefully.'
    }
} finally {
    if (-not $adoptedProcess.HasExited) {
        Stop-Process -Id $adoptedProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $adoptedProcess.Dispose()
}
Write-Host 'host-adopt passed'

# The explicit shell quit/restart path stops the owned host synchronously.
$case = New-Case 'host-stop'
New-Item -ItemType Directory -Force -Path (Split-Path $case.Bundled) | Out-Null
Copy-Item $windowStub $case.Bundled
$stopPid = Join-Path $case.Root 'stop-pid.txt'
$stopClosed = Join-Path $case.Root 'stop-closed.txt'
$stopProcess = Start-WindowHost $case.Bundled $stopClosed $stopPid
try {
    Wait-WindowHost $stopPid
    Add-HostFixture $case
    $null = Invoke-Fixture $case 'glazier-host-smoke.qml' @{
        CAELESTIA_SHELL_LIVE = '1'
        GLAZIER_HOST_OUTPUT = $case.HostOutput
        GLAZIER_EXPECT_ADOPT = '1'
        GLAZIER_STOP_AFTER_ADOPT = '1'
        GLAZIER_EXPECTED_THEME = (Join-Path $case.Profile 'state\caelestia\theme-tokens.json').Replace('\', '/')
    }
    if (Test-Path -LiteralPath $case.HostOutput) { throw 'The stopped host was started again.' }
    if (-not $stopProcess.WaitForExit(5000)) { throw 'The owned host was not stopped.' }
    if (-not (Test-Path -LiteralPath $stopClosed)) { throw 'The owned host was not stopped gracefully.' }
} finally {
    if (-not $stopProcess.HasExited) {
        Stop-Process -Id $stopProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $stopProcess.Dispose()
}
Write-Host 'host-stop passed'

# --- static ownership and packaging contracts ------------------------------
$keybinds = Get-Content -LiteralPath (Join-Path $repo 'defaults\windows\keybinds.json') -Raw | ConvertFrom-Json
$screenshot = @($keybinds.binds | Where-Object { $_.name -in @('caelestia:screenshot', 'caelestia:screenshotFreeze') })
$record = @($keybinds.binds | Where-Object { $_.name -eq 'caelestia:record' })
if (($screenshot | ForEach-Object keys) -join ',' -ne 'PrintScreen,Win+Shift+S') {
    throw 'Screenshot is not bound to exactly PrintScreen and Win+Shift+S.'
}
if (($record | ForEach-Object keys) -join ',' -ne 'Win+Shift+R') {
    throw 'Recording is not bound to exactly Win+Shift+R.'
}
foreach ($bind in @($screenshot + $record)) {
    if ($bind.register) { throw 'A Glazier chord uses RegisterHotKey and races the tool.' }
    if (-not $bind.since) { throw 'A new default Glazier bind has no since marker for legacy profiles.' }
}
foreach ($chord in @('PrintScreen', 'Win+Shift+S', 'Win+Shift+R')) {
    if (@($keybinds.binds | Where-Object { $_.keys -eq $chord }).Count -ne 1) {
        throw "$chord has more than one owner."
    }
}
$adapter = Get-Content -LiteralPath (Join-Path $repo 'windows\shell\adapters\services\Glazier.qml') -Raw
if ($adapter -match 'Programs[\\/]Glazier') { throw 'Glazier still resolves a separate install location.' }
if ($adapter -notmatch '--no-hotkeys' -or $adapter -notmatch '--theme-file') {
    throw 'The shell does not launch Glazier with its owned-hotkey and theme options.'
}
$shellEntry = Get-Content -LiteralPath (Join-Path $repo 'windows\shell\shell.qml') -Raw
if ($shellEntry -notmatch 'Glazier\.stopHost\(false\)' -or $shellEntry -notmatch 'Glazier\.stopHost\(true\)') {
    throw 'Shell quit/restart does not stop the owned Glazier host.'
}
Write-Host "Glazier offscreen and ownership tests passed. Temp files: $run"
