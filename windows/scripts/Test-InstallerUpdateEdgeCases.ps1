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

    # Release packaging can run on a hosted administrator token, but only its
    # disposable payload assembly may bypass the per-user elevation refusal.
    # The fixture guard throws whenever the copied installer consults it. A
    # payload-assembly invocation must therefore succeed without touching the
    # simulated user profile, while the same installer in normal mode must fail
    # before creating its prefix. The minimal build is never launched: Qt
    # deployment is an inert locally compiled executable and the shell payload
    # only needs real source files for assembly.
    $assemblyFixture = Join-Path $root 'payload-assembly'
    [IO.Directory]::CreateDirectory($assemblyFixture) | Out-Null
    $fixtureScripts = Join-Path $assemblyFixture 'scripts'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.') -Destination $fixtureScripts -Recurse
    $installerCopy = Join-Path $fixtureScripts 'Install-Caelestia.ps1'
    $installerCopyText = [IO.File]::ReadAllText($installerCopy)
    $captureBoundary = ". (Join-Path `$repoRoot 'windows\capture\Source.ps1')"
    Assert ($installerCopyText.Contains($captureBoundary)) 'Installer fixture import boundary changed.'
    $guardInjection = $captureBoundary + "`r`nfunction Assert-CaelestiaInstallerNotElevated { param([object]`$Elevated = `$null, [string]`$TokenUser = '', [string]`$ConsoleSessionUser = '') throw 'SIMULATED-ELEVATED-TOKEN' }"
    $installerCopyText = $installerCopyText.Replace($captureBoundary, $guardInjection)
    Write-Utf8NoBom $installerCopy $installerCopyText

    $assemblyBuild = Join-Path $assemblyFixture 'build'
    $assemblyQt = Join-Path $assemblyFixture 'qt'
    $assemblyVc = Join-Path $assemblyFixture 'vc'
    foreach ($directory in @(
        (Join-Path $assemblyBuild 'quickshell'),
        (Join-Path $assemblyBuild 'install\qml\Caelestia\Windows'),
        (Join-Path $assemblyBuild 'install\qml\Caelestia\lib'),
        (Join-Path $assemblyBuild 'install\qml\M3Shapes'),
        (Join-Path $assemblyQt 'bin'), $assemblyVc)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $inboxPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Copy-Item -LiteralPath $inboxPowerShell -Destination (Join-Path $assemblyBuild 'quickshell\qs.exe')
    Copy-Item -LiteralPath $inboxPowerShell -Destination (Join-Path $assemblyBuild 'install\caelestia-capture.exe')
    Write-Utf8NoBom (Join-Path $assemblyBuild 'install\qml\Caelestia\Windows\qmldir') 'module fixture'
    Write-Utf8NoBom (Join-Path $assemblyBuild 'install\qml\M3Shapes\qmldir') 'module fixture'
    foreach ($file in @(
        (Join-Path $assemblyBuild 'install\qml\M3Shapes\m3shapes.dll'),
        (Join-Path $assemblyBuild 'install\qml\Caelestia\lib\fixture.dll'),
        (Join-Path $assemblyVc 'msvcp140.dll'), (Join-Path $assemblyVc 'vcruntime140.dll'),
        (Join-Path $assemblyVc 'vcruntime140_1.dll'))) {
        Write-Utf8NoBom $file 'fixture'
    }
    $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Assert (Test-Path -LiteralPath $csc -PathType Leaf) 'The inert deployment fixture requires the inbox C# compiler.'
    $emptySource = Join-Path $assemblyFixture 'empty.cs'
    Write-Utf8NoBom $emptySource 'public static class X { public static void Main() {} }'
    $windeployqt = Join-Path $assemblyQt 'bin\windeployqt.exe'
    $cscOutput = @(& $csc /nologo /out:$windeployqt $emptySource 2>&1)
    Assert ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $windeployqt -PathType Leaf)) ('Could not compile the inert deployment fixture: ' + ($cscOutput | Out-String))

    $assemblyHarness = Join-Path $assemblyFixture 'harness.ps1'
    $assemblyHarnessText = @'
param([string]$Mode, [string]$Installer, [string]$RepoRoot, [string]$BuildRoot, [string]$QtPrefix, [string]$VCRuntimeRoot, [string]$Prefix, [string]$ProfileRoot, [string]$FakeAppData, [string]$FakeHome)
$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $FakeAppData
$env:USERPROFILE = $FakeHome
$arguments = @{
    BuildRoot = $BuildRoot; QtPrefix = $QtPrefix; VCRuntimeRoot = $VCRuntimeRoot
    Prefix = $Prefix; ProfileRoot = $ProfileRoot; SourceRoot = $RepoRoot
    NoIntegration = $true; SkipSchemeRuntime = $true
}
if ($Mode -eq 'assembly') { $arguments.PayloadAssembly = $true }
& $Installer @arguments
'@
    Write-Utf8NoBom $assemblyHarness $assemblyHarnessText
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $assemblyPrefix = Join-Path $assemblyFixture 'app-prefix'
    $assemblyProfile = Join-Path $assemblyFixture 'scratch-profile'
    $assemblyAppData = Join-Path $assemblyFixture 'fake-localappdata'
    $assemblyHome = Join-Path $assemblyFixture 'fake-home'
    $assemblyOutput = @(& $pwsh -NoProfile -NonInteractive -File $assemblyHarness `
        -Mode assembly -Installer $installerCopy -RepoRoot $repoRoot -BuildRoot $assemblyBuild -QtPrefix $assemblyQt `
        -VCRuntimeRoot $assemblyVc -Prefix $assemblyPrefix -ProfileRoot $assemblyProfile -FakeAppData $assemblyAppData -FakeHome $assemblyHome 2>&1)
    $assemblyExit = $LASTEXITCODE
    Assert ($assemblyExit -eq 0) ("Payload assembly under the simulated elevated token failed:`n" + ($assemblyOutput | Out-String))
    Assert ((($assemblyOutput | Out-String) -match 'Payload assembled') -and -not (($assemblyOutput | Out-String).Contains('SIMULATED-ELEVATED-TOKEN'))) 'Payload assembly consulted the per-user elevation guard.'
    Assert (Test-Path -LiteralPath (Join-Path $assemblyPrefix 'install.json') -PathType Leaf) 'Payload assembly did not publish its selector record.'
    # Redirecting USERPROFILE makes the pwsh host itself write its telemetry
    # and startup cache there. Those host artifacts are fixture noise; the
    # assertion is for Caelestia install, integration or profile state.
    $caelestiaUserWrites = @()
    foreach ($simulatedRoot in @($assemblyAppData, $assemblyHome)) {
        if (Test-Path -LiteralPath $simulatedRoot) {
            $caelestiaUserWrites += @(Get-ChildItem -LiteralPath $simulatedRoot -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^caelestia' })
        }
    }
    Assert ($caelestiaUserWrites.Count -eq 0) 'Payload assembly wrote Caelestia state to the simulated user profile.'

    $normalPrefix = Join-Path $assemblyFixture 'normal-prefix'
    $normalProfile = Join-Path $assemblyFixture 'normal-profile'
    $normalAppData = Join-Path $assemblyFixture 'normal-localappdata'
    $normalHome = Join-Path $assemblyFixture 'normal-home'
    $normalOutput = @(& $pwsh -NoProfile -NonInteractive -File $assemblyHarness `
        -Mode normal -Installer $installerCopy -RepoRoot $repoRoot -BuildRoot $assemblyBuild -QtPrefix $assemblyQt `
        -VCRuntimeRoot $assemblyVc -Prefix $normalPrefix -ProfileRoot $normalProfile -FakeAppData $normalAppData -FakeHome $normalHome 2>&1)
    $normalExit = $LASTEXITCODE
    Assert ($normalExit -ne 0 -and (($normalOutput | Out-String).Contains('SIMULATED-ELEVATED-TOKEN'))) 'Normal Install-Caelestia.ps1 did not refuse the simulated elevated token.'
    Assert (-not (Test-Path -LiteralPath $normalPrefix) -and -not (Test-Path -LiteralPath $normalProfile)) 'Elevated normal installation wrote install or profile state.'

    $releaseInstallerText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'))
    $releaseImport = ". (Join-Path `$payloadSource 'Caelestia-InstallCommon.ps1')"
    $releaseImportIndex = $releaseInstallerText.IndexOf($releaseImport, [StringComparison]::Ordinal)
    $releaseGuardIndex = $releaseInstallerText.IndexOf('Assert-CaelestiaInstallerNotElevated', $releaseImportIndex + 1, [StringComparison]::Ordinal)
    $releaseFloorIndex = $releaseInstallerText.IndexOf('if ([Environment]::OSVersion.Version.Build -lt 22000) {', [StringComparison]::Ordinal)
    Assert ($releaseImportIndex -ge 0 -and $releaseGuardIndex -gt $releaseImportIndex -and $releaseFloorIndex -gt $releaseGuardIndex) 'Install-CaelestiaRelease.ps1 lost its pre-prerequisite elevation refusal.'
    Assert (-not $releaseInstallerText.Contains('PayloadAssembly')) 'Install-CaelestiaRelease.ps1 exposes the release-assembly bypass.'
    $cmdText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install.cmd'))
    Assert ($cmdText.Contains('Install-CaelestiaRelease.ps1') -and -not $cmdText.Contains('PayloadAssembly')) 'Install.cmd no longer routes through the guarded release installer.'
    $releaseAssemblerText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'New-CaelestiaRelease.ps1'))
    Assert ($releaseAssemblerText.Contains('NoIntegration = $true; SkipSchemeRuntime = $true; PayloadAssembly = $true')) 'New-CaelestiaRelease.ps1 does not use the bounded payload-assembly mode.'
    Write-Output 'PASS payload assembly: elevated packaging is isolated while normal installers refuse elevation.'

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

    # Payload identity, not the first child generation, defines readiness. An
    # already-running old payload must never satisfy a newly selected one, while
    # a watchdog replacement under the same supervisor and payload must pass.
    $identityRoot = Join-Path $root 'identity-prefix'
    $identityRuntime = Join-Path $identityRoot 'versions\new'
    [IO.Directory]::CreateDirectory((Join-Path $identityRuntime 'shell')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $identityRoot 'versions\old')) | Out-Null
    Write-Utf8NoBom (Join-Path $identityRuntime 'shell\shell.qml') '// fixture payloadPath supervisorPid'
    [ordered]@{
        product = 'caelestia-windows'; version = 1; prefix = $identityRoot
        profile = (Join-Path $identityRoot 'profile'); installId = 'identity-test'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $identityRoot 'install.json') -Encoding UTF8
    Write-CaelestiaReadinessRecord (Get-CaelestiaReadinessRecordPath $identityRoot 'Caelestia-Start-identity') 'first-generation' 4321 0 $true `
        -PayloadPath $identityRuntime -SupervisorPid 4321
    function Get-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) [pscustomobject]@{ State = 'Ready' } }
    function Get-ScheduledTaskInfo { param($TaskName, $TaskPath, $ErrorAction) [pscustomobject]@{ LastTaskResult = 0; LastRunTime = [DateTime]::UtcNow } }
    $script:identityPayload = Join-Path $identityRoot 'versions\old'
    $script:identityGeneration = 'old-generation'
    $script:identitySupervisor = 9999
    function Invoke-CaelestiaIpc {
        param([string]$Prefix, [string]$Command, [int]$TimeoutMs = 10000)
        ('{"lifecycle":{"generation":"' + $script:identityGeneration + '","ready":true,"payloadPath":"' +
            $script:identityPayload.Replace('\', '\\') + '","supervisorPid":' + $script:identitySupervisor + '}}')
    }
    $wrongAccepted = $false
    try {
        Wait-CaelestiaReady $identityRoot -TimeoutSeconds 1 -TaskName 'Caelestia-Start-identity' `
            -ExpectedPayload $identityRuntime -RequireIdentity
        $wrongAccepted = $true
    } catch { }
    Assert (-not $wrongAccepted) 'An already-running old payload satisfied readiness for a new payload.'
    $script:identityPayload = $identityRuntime
    $script:identityGeneration = 'watchdog-replacement-generation'
    $script:identitySupervisor = 4321
    Wait-CaelestiaReady $identityRoot -TimeoutSeconds 3 -TaskName 'Caelestia-Start-identity' `
        -ExpectedPayload $identityRuntime -RequireIdentity
    Write-Output 'PASS readiness identity: wrong payload is rejected and same-supervisor replacement is accepted.'
    Remove-Item -LiteralPath Function:Invoke-CaelestiaIpc -ErrorAction SilentlyContinue

    # Execute the production receipt block with an injected write failure. The
    # verified ready state must survive as a warning, not become a failed launch.
    $startSourcePath = Join-Path $PSScriptRoot 'Start-Caelestia.ps1'
    $tokens = $null; $parseErrors = $null
    $startAst = [Management.Automation.Language.Parser]::ParseFile($startSourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Start-Caelestia.ps1 does not parse.'
    $receiptIf = $startAst.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if ($ReadinessRecordPath)') -and
        $node.Extent.Text.Contains('Write-CaelestiaReadinessRecord')
    }, $true)
    Assert ($null -ne $receiptIf) 'Start-Caelestia lost its production readiness receipt block.'
    $ReadinessRecordPath = Join-Path $root 'receipt.json'
    $readyState = [pscustomobject]@{ lifecycle = [pscustomobject]@{ generation = 'verified-generation' } }
    $process = [pscustomobject]@{ Id = 4321 }
    function Write-CaelestiaReadinessRecord { throw 'injected receipt write failure' }
    $receiptError = ''
    $receiptWarnings = $null
    try { $receiptWarnings = & ([scriptblock]::Create($receiptIf.Extent.Text)) 3>&1 } catch { $receiptError = $_.Exception.Message }
    Remove-Item -LiteralPath Function:Write-CaelestiaReadinessRecord -ErrorAction SilentlyContinue
    Remove-Variable -Name ReadinessRecordPath, readyState, process -ErrorAction SilentlyContinue
    Assert (-not $receiptError) ("Receipt write failure failed the healthy launch: " + $receiptError)
    Assert (($receiptWarnings | Out-String) -match 'Could not write the launch readiness receipt') 'Receipt write failure did not produce a warning.'
    $startSource = [IO.File]::ReadAllText($startSourcePath)
    Assert ($startSource.IndexOf('Wait-CaelestiaReady') -lt $startSource.IndexOf('Write-CaelestiaReadinessRecord')) 'Receipt is no longer written only after IPC readiness.'
    Write-Output 'PASS receipt fault: write failure is best-effort after verified IPC readiness.'

    # Prerequisite staging must let a different administrator account execute
    # the verified redistributable, while administrators receive no write or
    # modify rights. Run the production ACL constructor directly.
    $releaseSourcePath = Join-Path $PSScriptRoot 'Install-CaelestiaRelease.ps1'
    $tokens = $null; $parseErrors = $null
    $releaseAst = [Management.Automation.Language.Parser]::ParseFile($releaseSourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Install-CaelestiaRelease.ps1 does not parse.'
    $aclFunction = $releaseAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ReleasePrivateStagingDirectory'
    }, $true)
    Assert ($null -ne $aclFunction) 'Release prerequisite staging ACL constructor is missing.'
    . ([scriptblock]::Create($aclFunction.Extent.Text))
    $stagingAclPath = New-ReleasePrivateStagingDirectory 'acl-test'
    try {
        $acl = Get-Acl -LiteralPath $stagingAclPath
        $adminRules = @($acl.Access | Where-Object {
            try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544' } catch { $false }
        })
        Assert ($adminRules.Count -ge 1) 'BUILTIN\Administrators has no prerequisite staging ACE.'
        $adminRule = $adminRules[0]
        $readExecute = [Security.AccessControl.FileSystemRights]::ReadAndExecute
        $allowed = $readExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
        Assert ($adminRule.FileSystemRights -eq $allowed) 'BUILTIN\Administrators received more than ReadAndExecute rights.'
    } finally { Remove-Item -LiteralPath $stagingAclPath -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output 'PASS prerequisite ACL: administrators can execute but cannot modify staged bytes.'

    # pip compares PIP_CONFIG_FILE with os.devnull case-sensitively. Prove the
    # production lowercase spelling with real pip in a disposable venv whose
    # site pip.ini would otherwise be loaded.
    $pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Assert ($null -ne $pythonCommand) 'Real pip test requires python.'
    $pipVenv = Join-Path $root 'pip-venv'
    & $pythonCommand.Source -m venv $pipVenv 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Could not create the real pip test venv.'
    $venvPython = Join-Path $pipVenv 'Scripts\python.exe'
    Write-Utf8NoBom (Join-Path $pipVenv 'pip.ini') "[global]`nindex-url = https://invalid.example/simple`n"
    $oldPipConfig = $env:PIP_CONFIG_FILE
    try {
        $env:PIP_CONFIG_FILE = 'nul'
        $lowerOut = & $venvPython -I -m pip config get global.index-url 2>&1
        $lowerCode = $LASTEXITCODE
        $env:PIP_CONFIG_FILE = 'NUL'
        $upperOut = & $venvPython -I -m pip config get global.index-url 2>&1
        $upperCode = $LASTEXITCODE
    } finally { $env:PIP_CONFIG_FILE = $oldPipConfig }
    Assert ($lowerCode -ne 0) 'Lowercase nul still read site pip.ini.'
    Assert ($upperCode -eq 0 -and (($upperOut | Out-String) -match 'invalid\.example')) 'Uppercase NUL control did not read site pip.ini.'
    $schemeRuntimeSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1'))
    Assert ($schemeRuntimeSource.Contains("PIP_CONFIG_FILE'] = 'nul'")) 'Production pip isolation does not use lowercase nul.'
    Write-Output 'PASS pip isolation: real pip ignores site config only with lowercase nul.'

    # Scheduled task ownership parses argument fields and compares normalized
    # paths. A forward-slash spelling of the same prefix must still be owned.
    $uninstallSourcePath = Join-Path $PSScriptRoot 'Uninstall-Caelestia.ps1'
    $tokens = $null; $parseErrors = $null
    $uninstallAst = [Management.Automation.Language.Parser]::ParseFile($uninstallSourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert ($parseErrors.Count -eq 0) 'Uninstall-Caelestia.ps1 does not parse.'
    $argumentFunction = $uninstallAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CaelestiaQuotedTaskArgument'
    }, $true)
    Assert ($null -ne $argumentFunction) 'Uninstall lost its scheduled-task argument parser.'
    . ([scriptblock]::Create($argumentFunction.Extent.Text))
    $taskPrefix = Join-Path $root 'task prefix'
    [IO.Directory]::CreateDirectory($taskPrefix) | Out-Null
    $forwardPrefix = $taskPrefix.Replace('\', '/')
    $forwardLauncher = (Join-Path $taskPrefix 'Start-Caelestia.ps1').Replace('\', '/')
    $taskArguments = '-NoProfile -File "' + $forwardLauncher + '" -Prefix "' + $forwardPrefix + '"'
    Assert ((Get-CaelestiaQuotedTaskArgument $taskArguments 'Prefix') -eq $forwardPrefix) 'Task parser did not extract the prefix argument.'
    Assert (Test-CaelestiaSamePath (Get-CaelestiaQuotedTaskArgument $taskArguments 'Prefix') $taskPrefix) 'Normalized prefix comparison failed.'
    Assert (Test-CaelestiaSamePath (Get-CaelestiaQuotedTaskArgument $taskArguments 'File') (Join-Path $taskPrefix 'Start-Caelestia.ps1')) 'Normalized launcher comparison failed.'
    $uninstallSource = [IO.File]::ReadAllText($uninstallSourcePath)
    Assert (-not $uninstallSource.Contains('$arguments -ne $launchArguments')) 'Uninstall returned to raw argument string equality.'
    Write-Output 'PASS uninstall task matching: parsed arguments compare normalized paths.'

    # The direct GPO fallback uses an explicit CreateProcess wrapper. Exercise a
    # real same-session launch and assert both the breakaway request and the
    # access-denied fallback are present in production.
    $outOfJobScript = Join-Path $root 'out-of-job-child.ps1'
    $outOfJobMarker = Join-Path $root 'out-of-job-marker'
    Write-Utf8NoBom $outOfJobScript ('[IO.File]::WriteAllText("' + $outOfJobMarker.Replace('\', '\\') + '", "ok")')
    $breakawayUsed = $false
    $outOfJobPid = Start-CaelestiaOutOfJobProcess (Get-CaelestiaPowerShellPath) ('-NoProfile -NonInteractive -File "' + $outOfJobScript + '"') $env:USERPROFILE ([ref]$breakawayUsed)
    Assert ($outOfJobPid -gt 0) 'Out-of-job CreateProcess helper did not return a child PID.'
    $outOfJobDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $outOfJobMarker) -and [DateTime]::UtcNow -lt $outOfJobDeadline) { Start-Sleep -Milliseconds 25 }
    Assert (Test-Path -LiteralPath $outOfJobMarker) 'Out-of-job child did not execute.'
    $commonSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1'))
    Assert ($commonSource.Contains('CreateBreakawayFromJob') -and $commonSource.Contains('ERROR_ACCESS_DENIED')) 'Out-of-job launch lost breakaway or its access-denied fallback.'
    Write-Output 'PASS direct launch fallback: same-session CreateProcess helper runs with breakaway control.'

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
        return $null
    }
    function Wait-CaelestiaReady { param([string]$Prefix, [int]$TimeoutSeconds, [string]$TaskName = '', [string]$ExpectedPayload = '', [int]$ExpectedSupervisorPid = 0, [switch]$RequireIdentity) }
    function Start-CaelestiaOutOfJobProcess {
        param([string]$FilePath, [string]$Arguments, [string]$WorkingDirectory, [ref]$BreakawayUsed)
        $script:directLaunches++
        $script:directArguments += [string]$Arguments
        $BreakawayUsed.Value = $true
        return 4242
    }
    function Get-Process {
        param($Id, $ErrorAction)
        $process = [pscustomobject]@{ HasExited = $false }
        $process | Add-Member -MemberType ScriptMethod Dispose { }
        return $process
    }
    Start-CaelestiaDetached -Prefix $gpoPrefix -PreparedSchemeRuntime
    Assert ($script:directLaunches -eq 1) 'Registration denial did not use direct detached fallback.'
    Assert (($script:directArguments[0] -match [regex]::Escape('-PreparedSchemeRuntime'))) 'Direct fallback dropped prepared scheme runtime state.'
    $script:registerDenied = $false
    Start-CaelestiaDetached -Prefix $gpoPrefix -PreparedSchemeRuntime
    Assert ($script:directLaunches -eq 2) 'Task-start denial did not use direct detached fallback.'
    Remove-Item -LiteralPath Function:Get-Process, Function:Start-CaelestiaOutOfJobProcess, Function:Wait-CaelestiaReady -ErrorAction SilentlyContinue
    Write-Output 'PASS GPO fallback: registration and task-start denial launch directly with a diagnostic.'

    # Nexus update/rollback has a different contract from shell activation:
    # direct shell fallback cannot preserve the queue watchdog. When policy
    # refuses registration, the request must fail explicitly and leave only a
    # terminal failed journal, never a queued or working operation. Execute a
    # real fixture copy of Manage-Caelestia with only Task Scheduler boundaries
    # replaced; its prefix lock, journal write and error path are production.
    $manageFixture = Join-Path $root 'manage-gpo'
    $managePrefix = Join-Path $manageFixture 'prefix'
    $manageProfile = Join-Path $manageFixture 'profile'
    $manageCurrent = Join-Path $managePrefix 'versions\v2'
    $managePrevious = Join-Path $managePrefix 'versions\v1'
    [IO.Directory]::CreateDirectory($manageCurrent) | Out-Null
    [IO.Directory]::CreateDirectory($managePrevious) | Out-Null
    [IO.Directory]::CreateDirectory($manageProfile) | Out-Null
    foreach ($pair in @(@{ Path = $manageCurrent; Id = 'v2' }, @{ Path = $managePrevious; Id = 'v1' })) {
        [ordered]@{
            product = 'caelestia-windows'; version = 1; prefix = $pair.Path
            profile = $manageProfile; installId = 'manage-gpo'; installRoot = $managePrefix
            versionId = $pair.Id; sourceRevision = 'a' * 40; executableSha256 = '0' * 64
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $pair.Path 'install.json') -Encoding UTF8
    }
    [ordered]@{
        product = 'caelestia-windows'; version = 2; prefix = $managePrefix
        profile = $manageProfile; installId = 'manage-gpo'; current = 'v2'; previous = 'v1'
        sourceRevision = 'a' * 40; executableSha256 = '0' * 64
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $managePrefix 'install.json') -Encoding UTF8
    foreach ($name in @('Manage-Caelestia.ps1', 'Caelestia-InstallCommon.ps1', 'Caelestia-Versions.ps1',
        'Caelestia-Update.ps1', 'Caelestia-UpdateTrust.ps1', 'Caelestia-SemVer.ps1', 'Caelestia-UpdateSecurity.cs')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $managePrefix $name)
    }
    $manageCopy = Join-Path $managePrefix 'Manage-Caelestia.ps1'
    $manageText = [IO.File]::ReadAllText($manageCopy)
    $manageImport = ". (Join-Path `$PSScriptRoot 'Caelestia-Update.ps1')"
    Assert ($manageText.Contains($manageImport)) 'Manage-Caelestia fixture import boundary changed.'
    $schedulerFixture = $manageImport + @'

function New-ScheduledTaskAction { param($Execute, $WorkingDirectory, $Argument) [pscustomobject]@{ Execute = $Execute; WorkingDirectory = $WorkingDirectory; Arguments = $Argument } }
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) $null }
function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit, [switch]$StartWhenAvailable, $RestartCount, $RestartInterval) [pscustomobject]@{} }
function New-ScheduledTaskTrigger { param([switch]$Once, $At) [pscustomobject]@{} }
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Principal, $Settings, $ErrorAction)
    throw [UnauthorizedAccessException]::new('Group Policy blocks maintenance registration.')
}
function Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm, $ErrorAction) }
'@
    $manageText = $manageText.Replace($manageImport, $schedulerFixture)
    Write-Utf8NoBom $manageCopy $manageText
    $manageOutput = @(& $pwsh -NoProfile -NonInteractive -File $manageCopy -Prefix $managePrefix -Command Rollback 2>&1)
    $manageExit = $LASTEXITCODE
    $manageTextOut = $manageOutput | Out-String
    Assert ($manageExit -ne 0) 'Manage-Caelestia unexpectedly queued rollback while registration was denied.'
    Assert ($manageTextOut.Contains('Task Scheduler is blocked by policy') -and $manageTextOut.Contains('was not queued') -and
        $manageTextOut.Contains('Manage-Caelestia.ps1 -Command Rollback -Wait')) ('Manage-Caelestia did not surface manual GPO recovery instructions. Output: ' + $manageTextOut)
    $operationJournal = Join-Path $manageProfile 'state\update-operation.json'
    Assert (Test-Path -LiteralPath $operationJournal -PathType Leaf) 'Registration failure did not write a terminal operation journal.'
    $operationState = Get-Content -LiteralPath $operationJournal -Raw | ConvertFrom-Json
    Assert ($operationState.phase -eq 'failed' -and $operationState.kind -eq 'rollback') 'GPO registration failure left a nonterminal or corrupt operation journal.'
    Write-Output 'PASS Nexus GPO refusal: update state reaches terminal failure with manual recovery instructions.'

    # Multi-session taskbar coordination is behavioral, not textual. Compile a
    # fixture copy whose only changed boundaries are the disposable coordination
    # key and file-backed MMTaskbarEnabled storage, then prove a second live
    # owner blocks premature restoration and a dead/removed owner does not.
    $taskbarCase = Join-Path $root 'taskbar-multisession'
    [IO.Directory]::CreateDirectory($taskbarCase) | Out-Null
    $taskbarHarness = Join-Path $PSScriptRoot 'InstallerUpdate-TaskbarFixture.ps1'
    Assert (Test-Path -LiteralPath $taskbarHarness -PathType Leaf) 'Taskbar multi-session fixture is missing.'
    $taskbarKey = 'Software\CaelestiaTest-' + [guid]::NewGuid().ToString('N') + '\TaskbarSuppression'
    $taskbarOutput = @(& $pwsh -NoProfile -NonInteractive -File $taskbarHarness `
        -Common (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1') `
        -SourcePath (Join-Path $PSScriptRoot 'DesktopTakeover.cs') `
        -CaseRoot $taskbarCase -KeyName $taskbarKey 2>&1)
    $taskbarExit = $LASTEXITCODE
    Remove-Item -LiteralPath ('HKCU:\' + $taskbarKey) -Recurse -Force -ErrorAction SilentlyContinue
    Assert ($taskbarExit -eq 0 -and (($taskbarOutput | Out-String).Contains('TASKBAR-MULTISESSION-PASS'))) ("Taskbar multi-session fixture failed:`n" + ($taskbarOutput | Out-String))
    Write-Output 'PASS taskbar multi-session: shared baseline and live-owner restore coordination.'

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
