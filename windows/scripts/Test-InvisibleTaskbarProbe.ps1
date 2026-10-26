[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1, 60)][int]$Seconds = 5,
    [ValidateRange(20, 1000)][int]$IntervalMilliseconds = 100
)
$ErrorActionPreference = 'Stop'
# Deliberately not run by automated tests. Screen captures may contain private data.
# The operator must stop the real supervisor first and leave Explorer taskbars visible.
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
Add-Type -AssemblyName System.Drawing
$directory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $directory) { throw 'OutputDirectory must not already exist.' }
$mutex = New-Object Threading.Mutex($false, [Caelestia.Takeover.Supervisor]::MutexName)
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'A desktop supervisor is active. Stop it before this probe.' }
    # Capture obtains taskbar and monitor coordinates in per-monitor v2 pixels.
    $snapshot = [Caelestia.Takeover.Native]::Capture()
    $bars = @($snapshot.Bars)
    if ($bars.Count -eq 0 -or @($bars | Where-Object { -not $_.Visible }).Count -ne 0) {
        throw 'All Explorer taskbars must exist and be visible before running the probe.'
    }
    New-Item -ItemType Directory -Path $directory | Out-Null
    $snapshotPath = Join-Path $directory 'desktop-before.json'
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $restoreErrors = New-Object 'System.Collections.Generic.List[string]'
    $mutationStarted = $false
    function Save-TaskbarCapture($bar, [string]$name) {
        $displays = @($snapshot.Displays | Where-Object { $_.Device -eq $bar.Device })
        if ($displays.Count -ne 1) { throw "Cannot identify monitor for taskbar $($bar.Handle)." }
        # The entire monitor covers the collapsed edge strip and any revealed
        # taskbar position, including slide animation and non-bottom edges.
        $bounds = $displays[0].Bounds
        $width = $bounds.Right - $bounds.Left
        $height = $bounds.Bottom - $bounds.Top
        if ($width -le 0 -or $height -le 0) { throw 'Monitor rectangle is empty.' }
        $previousDpi = [Caelestia.Takeover.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
        if ($previousDpi -eq [IntPtr]::Zero) { throw 'Cannot set per-monitor v2 DPI awareness for screen capture.' }
        try {
            $bitmap = New-Object Drawing.Bitmap($width, $height)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try { $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size) }
                finally { $graphics.Dispose() }
                $path = Join-Path $directory $name
                $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
                return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            } finally { $bitmap.Dispose() }
        } finally { [void][Caelestia.Takeover.Native]::SetThreadDpiAwarenessContext($previousDpi) }
    }
    try {
        foreach ($bar in $bars) {
            $name = 'baseline-{0}.png' -f $bar.Handle
            $hash = Save-TaskbarCapture $bar $name
            $samples.Add([pscustomobject]@{ ElapsedMilliseconds = -1; Handle = $bar.Handle
                Visible = $bar.Visible; Image = $name; Sha256 = $hash })
        }
        # Capture every original region and commit one complete recovery record
        # before applying anything. The helper also handles PowerShell 5.1 nulls.
        [Caelestia.Takeover.Native]::PrepareRegions($snapshotPath, $snapshot, $snapshot.Bars)
        $mutationStarted = $true
        foreach ($saved in $snapshot.Regions) {
            [Caelestia.Takeover.Native]::ApplyEmptyRegion($saved)
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $index = 0
        while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
            $currentDesktop = [Caelestia.Takeover.Native]::Capture()
            $current = @($currentDesktop.Bars)
            if ($current.Count -ne $snapshot.Regions.Count) { throw 'Taskbar set changed during probe. Stopping for restoration.' }
            foreach ($bar in $current) {
                if (-not ($snapshot.Regions | Where-Object { $_.Handle -eq $bar.Handle -and $_.Owner -eq $bar.Owner })) {
                    throw 'Taskbar set changed during probe. Stopping for restoration.'
                }
                if (-not ($bars | Where-Object { $_.Handle -eq $bar.Handle -and $_.Owner -eq $bar.Owner -and $_.Device -eq $bar.Device })) {
                    throw 'Taskbar monitor changed during probe. Stopping for restoration.'
                }
                $originalDisplay = @($snapshot.Displays | Where-Object { $_.Device -eq $bar.Device })
                $currentDisplay = @($currentDesktop.Displays | Where-Object { $_.Device -eq $bar.Device })
                if ($originalDisplay.Count -ne 1 -or $currentDisplay.Count -ne 1 -or
                    $originalDisplay[0].Bounds.Left -ne $currentDisplay[0].Bounds.Left -or
                    $originalDisplay[0].Bounds.Top -ne $currentDisplay[0].Bounds.Top -or
                    $originalDisplay[0].Bounds.Right -ne $currentDisplay[0].Bounds.Right -or
                    $originalDisplay[0].Bounds.Bottom -ne $currentDisplay[0].Bounds.Bottom) {
                    throw 'Monitor geometry changed during probe. Stopping for restoration.'
                }
                $name = 'sample-{0:D5}-{1}.png' -f $index, $bar.Handle
                $hash = Save-TaskbarCapture $bar $name
                $samples.Add([pscustomobject]@{ ElapsedMilliseconds = $clock.ElapsedMilliseconds
                    Handle = $bar.Handle; Visible = $bar.Visible; Image = $name; Sha256 = $hash })
            }
            $index++
            Start-Sleep -Milliseconds $IntervalMilliseconds
        }
    } finally {
        foreach ($saved in $(if ($mutationStarted) { $snapshot.Regions })) {
            try {
                [Caelestia.Takeover.Native]::RestoreRegion($saved)
                $bar = @([Caelestia.Takeover.Native]::Taskbars() | Where-Object {
                    $_.Handle -eq $saved.Handle -and $_.Owner -eq $saved.Owner
                })
                if ($bar.Count -ne 1) { throw "Taskbar $($saved.Handle) no longer exists; Explorer restart resets its region." }
                $actual = [Caelestia.Takeover.Native]::CaptureRegion($bar[0])
                if ($null -eq $actual) { throw "Taskbar $($saved.Handle) disappeared during verification." }
                if ($actual.ProcessStartTicks -ne $saved.ProcessStartTicks -or $actual.RegionData -cne $saved.RegionData) {
                    throw "Taskbar $($saved.Handle) region did not verify."
                }
            } catch { $restoreErrors.Add($_.Exception.Message) }
        }
        $samples | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $directory 'samples.json') -Encoding UTF8
        if ($restoreErrors.Count) { throw ("Restoration failed: " + ($restoreErrors -join '; ') + ". Recovery snapshot: $snapshotPath") }
    }
    Write-Output "Restoration verified. Inspect full-monitor PNGs, including edge-hover reveals; Visible is not a pixel or hit-test. Snapshot: $snapshotPath"
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
