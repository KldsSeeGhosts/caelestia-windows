[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [ValidateRange(0, 15)][int]$ScreenIndex = 0,
    [string]$OutputRoot
)

# Live check for the combined prototype's opt-in bar and border reservations:
# Full screen reserves the bar on the left and the border on the other edges;
# turning Full screen off (or quitting) restores the work area. The
# run is short and the work area is restored even when an assertion fails.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $OutputRoot) { $OutputRoot = Join-Path $BuildRoot ('combined-appbar-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
# qs.exe needs the Qt runtime on PATH when invoked directly for IPC.
$env:PATH = "$QtPrefix\bin;$env:PATH"
$failure = $null
$prototypePid = $null

function Get-DesktopSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath (Join-Path $OutputRoot "$Name.json") | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-WorkAreas($State) {
    # PSCustomObject, not an ordered dictionary: dictionaries enumerate when
    # piped, which silently breaks later Where-Object matching.
    @($State.monitors | ForEach-Object {
        [pscustomobject]@{ deviceName = $_.deviceName; primary = $_.primary; work = $_.physicalWorkArea; scalePercent = $_.scalePercent }
    })
}
function Invoke-PrototypeIpc([int]$TargetPid, [string]$Method, [string[]]$Arguments = @()) {
    & $exe ipc --pid $TargetPid call prototype $Method @Arguments 2>&1 | ForEach-Object { "$_" }
}

$before = Get-DesktopSnapshot 'desktop-before'
$beforeWork = @{}
foreach ($m in (Get-WorkAreas $before)) { $beforeWork[$m.deviceName] = $m.work }
try {
    $launchOutput = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -Combined -ScaleFactor native -ScreenIndex $ScreenIndex
    $launchOutput | Set-Content -LiteralPath (Join-Path $OutputRoot 'launch.log') -Encoding UTF8
    $prototypePid = [int]([regex]::Match(($launchOutput -join "`n"), 'PID (\d+)').Groups[1].Value)
    Assert ($prototypePid -gt 0) 'Could not parse the prototype PID from the launcher output.'

    # Wait until the instance answers IPC, then read the live geometry.
    $state = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $raw = Invoke-PrototypeIpc $prototypePid 'state'
        try { $state = $raw | ConvertFrom-Json } catch { $state = $null }
        if ($state -and $state.barZone -gt 0) { break }
        Start-Sleep -Milliseconds 500
        if ($prototypePid -and -not (Get-Process -Id $prototypePid -ErrorAction SilentlyContinue)) {
            throw 'The prototype exited before answering IPC.'
        }
    }
    Assert ($null -ne $state -and $state.barZone -gt 0) 'The prototype never answered IPC with a bar zone.'
    $dpr = [double]$state.dpr
    $zoneLogical = [int]$state.barZone
    $expectedPhysical = [int][Math]::Round($zoneLogical * $dpr)
    $expectedBorder = [int][Math]::Round([double]$state.borderZone * $dpr)
    Invoke-PrototypeIpc $prototypePid 'setFullScreen' @('true') | Set-Content -LiteralPath (Join-Path $OutputRoot 'set-fullscreen-true.log') -Encoding UTF8

    # Wait for the reservation to appear on exactly one monitor.
    $reserved = $null
    $diffs = @()
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $reserved = Get-DesktopSnapshot 'desktop-reserved'
        $diffs = @(Get-WorkAreas $reserved | ForEach-Object {
            $base = $beforeWork[$_.deviceName]
            [pscustomobject]@{ deviceName = $_.deviceName; deltaLeft = $_.work.left - $base.left; deltaWidth = $_.work.width - $base.width }
        })
        if (@($diffs | Where-Object { $_.deltaLeft -ne 0 -or $_.deltaWidth -ne 0 }).Count -gt 0) { break }
    }
    $diffJson = $diffs | ConvertTo-Json -Depth 5 -Compress
    $diffJson | Set-Content -LiteralPath (Join-Path $OutputRoot 'work-area-diffs.json') -Encoding UTF8
    $shrunk = @($diffs | Where-Object { $_.deltaLeft -gt 0 -and $_.deltaWidth -lt 0 })
    Assert ($shrunk.Count -eq 1) ("Expected exactly one monitor with a shrunk work area, found $($shrunk.Count): $diffJson")
    $delta = [int]$shrunk[0].deltaLeft
    Assert ([Math]::Abs($delta - $expectedPhysical) -le 2) ("Work area shrank by $delta physical px; expected about $expectedPhysical ($zoneLogical logical at dpr $dpr).")
    $reservedMonitor = (Get-WorkAreas $reserved | Where-Object { $_.deviceName -eq $shrunk[0].deviceName })[0]
    $beforeMonitorWork = $beforeWork[$shrunk[0].deviceName]
    Assert ([Math]::Abs($reservedMonitor.work.top - $beforeMonitorWork.top - $expectedBorder) -le 2) 'The top border was not reserved.'
    Assert ([Math]::Abs($beforeMonitorWork.right - $reservedMonitor.work.right - $expectedBorder) -le 2) 'The right border was not reserved.'
    Assert ([Math]::Abs($beforeMonitorWork.bottom - $reservedMonitor.work.bottom - $expectedBorder) -le 2) 'The bottom border was not reserved.'

    Invoke-PrototypeIpc $prototypePid 'setFullScreen' @('false') | Set-Content -LiteralPath (Join-Path $OutputRoot 'set-fullscreen-false.log') -Encoding UTF8
    $allSame = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $restored = Get-DesktopSnapshot 'desktop-restored'
        $allSame = $true
        foreach ($m in (Get-WorkAreas $restored)) {
            $base = $beforeWork[$m.deviceName]
            if (($m.work | ConvertTo-Json -Compress) -ne ($base | ConvertTo-Json -Compress)) { $allSame = $false }
        }
        if ($allSame) { break }
    }
    Assert $allSame 'Turning Full screen off did not restore the original work areas.'

    Invoke-PrototypeIpc $prototypePid 'quit' | Set-Content -LiteralPath (Join-Path $OutputRoot 'quit.log') -Encoding UTF8
    if ($prototypePid) { Wait-Process -Id $prototypePid -Timeout 20 -ErrorAction SilentlyContinue }
    if ($prototypePid -and (Get-Process -Id $prototypePid -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $prototypePid -Force
        Wait-Process -Id $prototypePid -Timeout 10 -ErrorAction SilentlyContinue
    }

    $summary = [ordered]@{
        passed = $true
        screenIndex = $ScreenIndex
        zoneLogical = $zoneLogical
        dpr = $dpr
        reservedPhysicalDelta = $delta
        expectedPhysicalDelta = $expectedPhysical
        expectedBorderPhysicalDelta = $expectedBorder
        reservedMonitor = $shrunk[0].deviceName
        output = $OutputRoot
    }
} catch {
    $failure = $_.ToString()
    $summary = [ordered]@{ passed = $false; failure = $failure; output = $OutputRoot }
} finally {
    # The work area must be restored even when an assertion failed: ask the
    # instance to quit, then fall back to killing the exact PID.
    if ($prototypePid -and (Get-Process -Id $prototypePid -ErrorAction SilentlyContinue)) {
        try { Invoke-PrototypeIpc $prototypePid 'setFullScreen' @('false') | Out-Null } catch {}
        try { Invoke-PrototypeIpc $prototypePid 'quit' | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
        if (Get-Process -Id $prototypePid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $prototypePid -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $prototypePid -Timeout 10 -ErrorAction SilentlyContinue
        }
    }
    $after = Get-DesktopSnapshot 'desktop-after'
    if ($summary.passed) {
        $beforeIdentity = (@(Get-WorkAreas $before | ForEach-Object { "$($_.deviceName):$($_.work | ConvertTo-Json -Compress)" }) -join ';') `
            + "|taskbarAutoHide=$($before.taskbar.autoHide)"
        $afterIdentity = (@(Get-WorkAreas $after | ForEach-Object { "$($_.deviceName):$($_.work | ConvertTo-Json -Compress)" }) -join ';') `
            + "|taskbarAutoHide=$($after.taskbar.autoHide)"
        if ($beforeIdentity -ne $afterIdentity) {
            $summary.passed = $false
            $summary.failure = "Work areas or taskbar state differed after the run: before=[$beforeIdentity] after=[$afterIdentity]"
        }
    }
    $summary.afterWorkAreas = @(Get-WorkAreas $after)
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputRoot 'result.json') -Encoding UTF8
}
$summary | ConvertTo-Json -Depth 8
if (-not $summary.passed) { throw $summary.failure }
