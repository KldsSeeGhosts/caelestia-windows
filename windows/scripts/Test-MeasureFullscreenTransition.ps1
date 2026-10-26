$ErrorActionPreference = 'Stop'
$dir = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-trace-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $backend = Join-Path $dir 'backend.jsonl'
    $taskbar = Join-Path $dir 'taskbar.jsonl'
    @(
        '{"event":"fullscreen","window":"a","active":true,"initial":false,"qpc":"1000","qpcFrequency":"1000","utc":"test"}'
        '{"event":"tiler_state","window":"a","state":"Suspended","qpc":"1100","qpcFrequency":"1000"}'
        '{"event":"work_area","qpc":"1200","qpcFrequency":"1000"}'
        '{"event":"fullscreen","window":"a","active":false,"initial":false,"qpc":"2000","qpcFrequency":"1000","utc":"test"}'
        '{"event":"placement_verified","window":"a","landed":false,"qpc":"2100","qpcFrequency":"1000"}'
        '{"event":"placement_verified","window":"a","landed":true,"qpc":"2250","qpcFrequency":"1000"}'
        '{"event":"fullscreen","window":"b","active":true,"initial":false,"qpc":"2300","qpcFrequency":"1000","utc":"test"}'
    ) | Set-Content -LiteralPath $backend
    @(
        '{"Operation":"hook-installed","MonotonicTicks":1050,"TickFrequency":1000,"VisibleBefore":false,"VisibleAfter":false}'
        '{"Operation":"show","Device":"one","VisibleBefore":true,"VisibleAfter":true,"MonotonicTicks":1150,"TickFrequency":1000}'
        '{"Operation":"hide","Device":"one","VisibleBefore":true,"VisibleAfter":false,"MonotonicTicks":1250,"TickFrequency":1000}'
        '{"Operation":"hide","Device":"two","VisibleBefore":true,"VisibleAfter":false,"MonotonicTicks":2200,"TickFrequency":1000}'
    ) | Set-Content -LiteralPath $taskbar
    $result = @(& (Join-Path $PSScriptRoot 'Measure-FullscreenTransition.ps1') $backend $taskbar)
    if ($result.Count -ne 3 -or $result[0].LatencyMs -ne 100 -or $result[1].LatencyMs -ne 250 -or
        $result[0].TaskbarVisibleIntervals[0].DurationMs -ne 100 -or
        $result[0].AppBarWorkAreaEvents.Count -ne 1 -or
        $null -ne $result[1].TaskbarVisibleIntervals[0].DurationMs -or
        $null -ne $result[2].LatencyMs) { throw 'Unexpected transition metrics.' }
    '{"QpcTicks":1,"QpcFrequency":999,"VisibleAfter":false}' | Add-Content -LiteralPath $taskbar
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'Measure-FullscreenTransition.ps1') $backend $taskbar | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Mixed frequencies were not rejected.' }
    Write-Host 'Transition measurement fixtures passed.'
} finally {
    foreach ($file in @('backend.jsonl', 'taskbar.jsonl')) {
        $path = Join-Path $dir $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Remove-Item -LiteralPath $dir -Force
}
