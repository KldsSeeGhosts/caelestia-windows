[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
. (Join-Path $PSScriptRoot 'Caelestia-Versions.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-edge-cases-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:assertions = 0
function Assert($Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
try {
    # A payload command never shares this process, even when both payload hosts
    # use PowerShell 7. Two invocations must therefore have two child PIDs, and
    # exact base64 serialization must preserve a profile-like argument with a
    # space, an apostrophe and a non-ASCII character.
    $edgeName = "O'Brien Caf" + [char]0x00E9 + ' Profile With Space'
    $edgePrefix = Join-Path $root $edgeName
    $launcherText = @'
param([string]$Prefix, [string]$Command = 'Start', [string]$TestPath = '')
"$PID|$Command|$TestPath" | Set-Content -LiteralPath (Join-Path $Prefix 'invocation.txt') -Encoding UTF8
'@
    $payloadA = Join-Path $root 'payload-a'
    $payloadB = Join-Path $root 'payload-b'
    Write-Utf8NoBom (Join-Path $payloadA 'Start-Caelestia.ps1') $launcherText
    Write-Utf8NoBom (Join-Path $payloadB 'Start-Caelestia.ps1') $launcherText
    Invoke-CaelestiaPayloadCommand $payloadA @{ Command = 'Start'; TestPath = $edgePrefix }
    Invoke-CaelestiaPayloadCommand $payloadB @{ Command = 'Start' }
    $first = (Get-Content -LiteralPath (Join-Path $payloadA 'invocation.txt') -Raw).Trim()
    $second = (Get-Content -LiteralPath (Join-Path $payloadB 'invocation.txt') -Raw).Trim()
    $firstPid = [int]($first -split '\|')[0]
    $secondPid = [int]($second -split '\|')[0]
    Assert ($firstPid -ne $PID -and $secondPid -ne $PID -and $firstPid -ne $secondPid) 'Same-edition payload commands reused the caller process.'
    Assert ($first.EndsWith('|' + $edgePrefix)) 'Payload argument serialization changed an edge-case profile path.'
    Write-Output 'PASS cross-version dispatch: payload commands execute out of process and preserve edge-case paths.'

    # A process that already compiled one payload revision must refuse a second
    # revision instead of silently reusing the first assembly across a protocol
    # boundary. The child proves real compilation/loading isolation in one
    # process; the modified source forces different inputs and bytes.
    $assemblyA = Join-Path $root 'assembly-a'
    $assemblyB = Join-Path $root 'assembly-b'
    [IO.Directory]::CreateDirectory($assemblyA) | Out-Null
    [IO.Directory]::CreateDirectory($assemblyB) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -Destination (Join-Path $assemblyA 'DesktopTakeover.cs')
    $revisionA = [IO.File]::ReadAllText((Join-Path $assemblyA 'DesktopTakeover.cs'))
    $revisionB = $revisionA.Replace('v = 1, type = "welcome"', 'v = 2, type = "welcome"')
    Assert ($revisionA -cne $revisionB) 'The cross-version fixture could not inject a different handshake.'
    Write-Utf8NoBom (Join-Path $assemblyB 'DesktopTakeover.cs') $revisionB
    $probeScript = Join-Path $root 'assembly-probe.ps1'
    $probeText = @'
param([string]$Common, [string]$First, [string]$Second)
$ErrorActionPreference = 'Stop'
. $Common
Import-CaelestiaDesktopTakeover -ScriptRoot $First -SourceOnly
Import-CaelestiaDesktopTakeover -ScriptRoot $First -SourceOnly
try {
    Import-CaelestiaDesktopTakeover -ScriptRoot $Second -SourceOnly
    'MISMATCH-ACCEPTED'
} catch {
    'MISMATCH-REFUSED:' + $_.Exception.Message
}
exit 0
'@
    Write-Utf8NoBom $probeScript $probeText
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $probeOut = @(& $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probeScript `
        -Common (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1') -First $assemblyA -Second $assemblyB 2>&1)
    Assert ($LASTEXITCODE -eq 0) ("Assembly probe failed:`n" + ($probeOut -join "`n"))
    Assert (($probeOut -join "`n") -match 'MISMATCH-REFUSED:') ("Assembly probe output:`n" + ($probeOut -join "`n"))
    Write-Output 'PASS assembly mismatch: a loaded payload assembly is never reused for a different revision.'

    # Elevation refusal has two distinct cases: same-token elevation creates a
    # High-IL install a normal user cannot manage; a different token user is
    # over-the-shoulder elevation and not the console-session user at all.
    $sameUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $refusal = ''
    try {
        Assert-CaelestiaInstallerNotElevated -Elevated $true -TokenUser $sameUser -ConsoleSessionUser $sameUser
    } catch { $refusal = $_.Exception.Message }
    Assert ($refusal -match 'same-user elevation' -and $refusal -match 'without administrator elevation') 'Same-user elevation was not refused with an actionable diagnostic.'
    $refusal = ''
    try {
        Assert-CaelestiaInstallerNotElevated -Elevated $true -TokenUser 'CONTOSO\installer-admin' -ConsoleSessionUser 'CONTOSO\standard-user'
    } catch { $refusal = $_.Exception.Message }
    Assert ($refusal -match 'over-the-shoulder elevation' -and $refusal -match 'without administrator elevation') 'Over-the-shoulder elevation was not refused with an actionable diagnostic.'
    Assert-CaelestiaInstallerNotElevated -Elevated $false -TokenUser $sameUser -ConsoleSessionUser $sameUser
    Write-Output 'PASS elevation refusal: same-user and over-the-shoulder elevation are rejected.'

    # Readiness records are valid in a profile/prefix path containing spaces,
    # an apostrophe and non-ASCII characters. These paths are the IPC identity
    # boundary, so the exact prefix value is stored and read back unchanged.
    [IO.Directory]::CreateDirectory($edgePrefix) | Out-Null
    $edgeProfile = Join-Path $edgePrefix 'Profile Child'
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $edgePrefix
        profile = $edgeProfile; installId = 'edge-test'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $edgePrefix 'install.json') -Encoding UTF8
    $edgeRecordPath = Get-CaelestiaReadinessRecordPath $edgePrefix 'Caelestia-Start-edge'
    Write-CaelestiaReadinessRecord $edgeRecordPath 'edge-generation' 4321 0 $true
    $roundTrip = Read-CaelestiaReadinessRecord $edgeRecordPath
    Assert ($roundTrip.ready -and $roundTrip.generationId -eq 'edge-generation') 'Readiness record did not round-trip in an edge-case path.'
    $legacyLauncher = Join-Path $edgePrefix 'Start-Caelestia.ps1'
    Write-Utf8NoBom $legacyLauncher $launcherText
    $oldPlan = Get-CaelestiaLaunchPlan $edgePrefix -LaunchId 'Caelestia-Start-legacy'
    Assert ($oldPlan.Arguments -notmatch '-ReadinessRecordPath') 'The rollback plan sent a new launch argument to a legacy script.'
    Write-Utf8NoBom $legacyLauncher 'param([string]$ReadinessRecordPath)'
    $newPlan = Get-CaelestiaLaunchPlan $edgePrefix -LaunchId 'Caelestia-Start-edge'
    Assert ($newPlan.Arguments.Contains('-ReadinessRecordPath "' + $edgeRecordPath + '"')) 'The launch plan did not preserve the complete readiness record path.'
    # Use the stable router that Copy-CaelestiaRootEntries installs, and a
    # disposable payload that records precisely what the task passes through.
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-CaelestiaEntry.ps1') -Destination $legacyLauncher -Force
    foreach ($name in @('Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $edgePrefix
    }
    $edgeRuntime = Join-Path $edgePrefix 'versions\v1'
    Write-Utf8NoBom (Join-Path $edgeRuntime 'Start-Caelestia.ps1') @'
param([string]$Prefix, [string]$ReadinessRecordPath)
[IO.File]::WriteAllText((Join-Path $Prefix 'received.txt'), $ReadinessRecordPath)
'@
    $payloadRecord = [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $edgeRuntime; profile = $edgeProfile
        installId = 'edge-test'; installRoot = $edgePrefix; versionId = 'v1'
    }
    Write-CaelestiaJsonAtomic (Join-Path $edgeRuntime 'install.json') $payloadRecord
    Write-CaelestiaJsonAtomic (Join-Path $edgePrefix 'install.json') (New-CaelestiaRootRecord $edgePrefix ([pscustomobject]$payloadRecord) '')
    & $pwsh -NoProfile -NonInteractive -File $legacyLauncher -Prefix $edgePrefix -ReadinessRecordPath $edgeRecordPath
    Assert ($LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText((Join-Path $edgeRuntime 'received.txt')) -ceq $edgeRecordPath) 'The stable router lost the readiness argument.'
    Write-Output 'PASS profile paths: spaces, apostrophes and non-ASCII names preserve identity and readiness.'

    # Ready/0 scheduled tasks are a normal startup race. Once a durable ready
    # record exists, one final IPC readiness probe must succeed rather than
    # classifying a healthy shell as exited-before-ready. The injected IPC
    # fails until the post-Ready ScheduledTaskInfo boundary has been observed.
    $racePrefix = Join-Path $root 'race-prefix'
    [IO.Directory]::CreateDirectory($racePrefix) | Out-Null
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $racePrefix
        profile = (Join-Path $racePrefix 'profile'); installId = 'race-test'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $racePrefix 'install.json') -Encoding UTF8
    Write-CaelestiaReadinessRecord (Get-CaelestiaReadinessRecordPath $racePrefix 'Caelestia-Start-race') 'edge-generation' 4321 0 $true
    $script:raceInfoObserved = $false
    $script:raceIpcCalls = 0
    function Get-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) [pscustomobject]@{ State = 'Ready' } }
    function Get-ScheduledTaskInfo {
        param($TaskName, $TaskPath, $ErrorAction)
        $script:raceInfoObserved = $true
        [pscustomobject]@{ LastTaskResult = 0; LastRunTime = [DateTime]::UtcNow }
    }
    function Invoke-CaelestiaIpc {
        param([string]$Prefix, [string]$Command, [int]$TimeoutMs = 10000)
        $script:raceIpcCalls++
        if (-not $script:raceInfoObserved) { throw 'injected cold IPC' }
        '{"lifecycle":{"generation":"edge-generation","ready":true}}'
    }
    Wait-CaelestiaReady $racePrefix -TimeoutSeconds 5 -TaskName 'Caelestia-Start-race'
    Assert ($script:raceIpcCalls -ge 2) 'Ready race did not perform both cold and final IPC probes.'
    function Get-ScheduledTaskInfo {
        param($TaskName, $TaskPath, $ErrorAction)
        [pscustomobject]@{ LastTaskResult = 1; LastRunTime = [DateTime]::UtcNow }
    }
    $script:raceInfoObserved = $false
    try {
        Wait-CaelestiaReady $racePrefix -TimeoutSeconds 3 -TaskName 'Caelestia-Start-race'
        throw 'A nonzero Ready task result was accepted.'
    } catch {
        Assert ($_.Exception.Message -match 'exited before readiness') 'Nonzero Ready task failure lost its diagnostic.'
    }
    Write-Output 'PASS readiness race: Ready/0 plus durable ready state performs a final IPC probe.'

    # Group Policy can refuse either registration or task start. Both failures
    # take the same explicit direct detached fallback rather than aborting the
    # installation or update.
    $gpoPrefix = Join-Path $root 'gpo-prefix'
    Write-Utf8NoBom (Join-Path $gpoPrefix 'Start-Caelestia.ps1') $launcherText
    $script:directLaunches = 0
    $script:directArguments = @()
    $script:registerDenied = $true
    function New-ScheduledTaskAction { param($Execute, $WorkingDirectory, $Argument) [pscustomobject]@{ Execute = $Execute; WorkingDirectory = $WorkingDirectory; Arguments = $Argument } }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) $null }
    function New-ScheduledTaskSettingsSet { param() [pscustomobject]@{} }
    function Register-ScheduledTask {
        param($TaskName, $Action, $Trigger, $Principal, $Settings, $ErrorAction)
        if ($script:registerDenied) { throw [UnauthorizedAccessException]::new('Group Policy blocks task registration.') }
        [pscustomobject]@{ TaskName = $TaskName }
    }
    function Start-ScheduledTask {
        param($TaskName, $ErrorAction)
        throw [UnauthorizedAccessException]::new('Group Policy blocks task start.')
    }
    function Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm, $ErrorAction) }
    function Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) }
    function Start-Process {
        param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru, [switch]$Wait)
        if ($FilePath -like '*locked-powershell.exe') {
            return Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
        }
        $script:directLaunches++
        $script:directArguments += [string]$ArgumentList
        $process = [pscustomobject]@{ HasExited = $false }
        $process | Add-Member -MemberType ScriptMethod Dispose { }
        return $process
    }
    function Wait-CaelestiaReady { param([string]$Prefix, [int]$TimeoutSeconds, [string]$TaskName = '') }
    Start-CaelestiaDetached -Prefix $gpoPrefix -PreparedSchemeRuntime
    Assert ($script:directLaunches -eq 1) 'Registration denial did not use direct detached fallback.'
    Assert (($script:directArguments[0] -match [regex]::Escape('-PreparedSchemeRuntime'))) 'Direct fallback dropped prepared scheme runtime state.'
    $script:registerDenied = $false
    Start-CaelestiaDetached -Prefix $gpoPrefix -PreparedSchemeRuntime
    Assert ($script:directLaunches -eq 2) 'Task-start denial did not use direct detached fallback.'
    Write-Output 'PASS GPO fallback: registration and task-start denial launch directly with a diagnostic.'

    # The no-write-share lock used during Authenticode verification blocks file
    # replacement while still allowing CreateProcess to map and execute the
    # exact bytes being launched. This uses a copied inbox executable, never a
    # production executable or network download.
    $copyExe = Join-Path $root 'locked-powershell.exe'
    Copy-Item -LiteralPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $copyExe
    $lock = [IO.FileStream]::new($copyExe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $blocked = $false
        try { [IO.File]::WriteAllText($copyExe, 'replacement') } catch [IO.IOException] { $blocked = $true }
        Assert $blocked 'The verification file lock allowed replacement writes.'
        Assert ((Get-AuthenticodeSignature -FilePath $copyExe).Status -ne 'UnknownError') 'Authenticode could not read the locked EXE.'
        $lockedProcess = Start-Process -FilePath $copyExe -ArgumentList '-NoProfile','-NonInteractive','-Command','exit 0' -Wait -PassThru
        Assert ($lockedProcess.ExitCode -eq 0) 'FileShare.Read blocked CreateProcess.'
    } finally { $lock.Dispose() }
    Write-Output 'PASS release TOCTOU lock: writes are blocked while CreateProcess can execute verified bytes.'

    # Exercise an MSI read with the Windows Installer engine while the same
    # lock is live. Opening the database read-only needs no install or UAC.
    $msiPath = Join-Path $root 'locked-package.msi'
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($msiPath, 3)
    $database.Commit()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
    $lock = [IO.File]::Open($msiPath, 'Open', 'Read', 'Read')
    try {
        $database = $installer.OpenDatabase($msiPath, 0)
        Assert ($null -ne $database) 'Windows Installer could not read the locked MSI.'
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
    } finally {
        $lock.Dispose()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }

    # Run the real restart block with inert process commands. No desktop API
    # is called and an access-denied stop must not prevent the restart.
    $tokens = $null; $parseErrors = $null
    $restore = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Restore-Desktop.ps1'), [ref]$tokens, [ref]$parseErrors)
    $restart = $restore.Find({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$RestartExplorer' }, $true)
    Assert ($parseErrors.Count -eq 0 -and $null -ne $restart) 'Restore-Desktop lost its Explorer restart block.'
    & {
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $stopped = [Collections.Generic.List[int]]::new()
        $launched = [Collections.Generic.List[string]]::new()
        function Get-Process {
            param($Name, $ErrorAction)
            [pscustomobject]@{ Id = 100; SessionId = $session }
            [pscustomobject]@{ Id = 101; SessionId = $session + 1 }
            [pscustomobject]@{ Id = 102; SessionId = $session }
        }
        function Stop-Process {
            param($InputObject, [switch]$Force, $ErrorAction)
            $stopped.Add($InputObject.Id)
            if ($InputObject.Id -eq 100) { throw [UnauthorizedAccessException]::new('Fixture refusal') }
        }
        function Start-Process { param($FilePath) $launched.Add($FilePath) }
        function Start-Sleep { param($Seconds) }
        $RestartExplorer = $true
        & ([scriptblock]::Create($restart.Extent.Text)) 3>$null
        Assert (($stopped -join ',') -eq '100,102' -and ($launched -join ',') -eq 'explorer.exe') 'Restore-Desktop touched another session or aborted on access denied.'
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install.cmd') -Destination $root
    Write-Utf8NoBom (Join-Path $root 'Install-CaelestiaRelease.ps1') 'param([switch]$NonInteractive); exit 17'
    $cmdOutput = '' | & $env:ComSpec /d /c ('""' + (Join-Path $root 'Install.cmd') + '" -nOnInTeRaCtIvE"')
    Assert ($LASTEXITCODE -eq 17 -and @($cmdOutput).Count -eq 1 -and $cmdOutput -match 'installation failed') 'Install.cmd paused or lost the installer exit code with -NonInteractive.'
    $schemeSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1')) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1'))
    foreach ($required in @('PIP_CONFIG_FILE', '--no-build-isolation', 'PythonCore', 'PyLauncher')) {
        Assert ($schemeSource.Contains($required)) "Scheme runtime provisioning lost $required."
    }
    Assert (-not $schemeSource.Contains('git+https://github.com/caelestia-dots/cli')) 'Scheme runtime still installs directly from git at runtime.'
    $takeoverSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DesktopTakeover.cs'))
    foreach ($required in @('0x0011', '0x0016', 'RestoreTaskbarsForSessionEnd')) {
        Assert ($takeoverSource.Contains($required)) "Desktop takeover lost session-end restoration hook $required."
    }
    $uninstallSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1'))
    Assert ($uninstallSource.Contains('Caelestia-Start-*') -and $uninstallSource.Contains('Unregister-ScheduledTask')) 'Uninstall lost orphaned launch task sweep.'
    Write-Output 'PASS static regressions: session scoping, no-pause, pinned scheme, session-end restore and task sweep.'

    Write-Output "INSTALLER_UPDATE_EDGE_CASES_PASS assertions=$script:assertions"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
