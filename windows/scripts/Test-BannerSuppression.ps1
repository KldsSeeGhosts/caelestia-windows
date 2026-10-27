[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Banner-Suppression.ps1'
$id = [guid]::NewGuid().ToString('N')
$testBase = 'Software\CaelestiaWindowsTest'
$testRoot = "$testBase\$id"
$state = Join-Path ([IO.Path]::GetTempPath()) "caelestia-banner-test-$id"
$journal = Join-Path $state 'banner-suppression.json'
$process = $null
$checks = 0
function Check($condition, $message) {
    $script:checks++
    if (-not $condition) { throw "Assertion failed: $message" }
}
function Key([string]$name, [bool]$write = $false) {
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$testRoot\$name", $write)
}
function Has-Banner([string]$name) {
    $key = Key $name
    try { return $key -and @($key.GetValueNames()) -contains 'ShowBanner' }
    finally { if ($key) { $key.Close() } }
}
function Value([string]$name) {
    $key = Key $name
    try { return $key.GetValue('ShowBanner', $null) } finally { $key.Close() }
}
function Start-Worker {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = "$PSHOME\powershell.exe"
    $info.Arguments = '-NoProfile -File "' + $helper + '" -StateDirectory "' + $state +
        '" -RegistryRoot "' + $testRoot + '" -Command Worker'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    return [Diagnostics.Process]::Start($info)
}
function Send($worker, [string]$text) {
    $worker.StandardInput.WriteLine($text)
    $worker.StandardInput.Flush()
    $result = $worker.StandardOutput.ReadLineAsync()
    if (-not $result.Wait(30000)) { throw 'Worker did not acknowledge within 30 seconds.' }
    if ($result.Result -ne 'ok') { throw "Worker failed: $($worker.StandardError.ReadToEnd())" }
}
try {
    New-Item -ItemType Directory -Path $state | Out-Null
    $root = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testRoot)
    foreach ($name in @('Absent', 'Present', 'Edited', 'Keep', 'WrongType', 'Windows.SystemToast.Sample', 'Windows.Defender.SecurityCenter', 'Nested\New')) {
        $key = $root.CreateSubKey($name)
        if ($name -in @('Present', 'Edited')) { $key.SetValue('ShowBanner', 1, [Microsoft.Win32.RegistryValueKind]::DWord) }
        if ($name -eq 'WrongType') { $key.SetValue('ShowBanner', 'keep', [Microsoft.Win32.RegistryValueKind]::String) }
        $key.Close()
    }
    $root.Close()
    $process = Start-Worker
    Send $process '{"command":"configure","keep":["Keep"]}'
    Check ((Value 'Present') -eq 0 -and (Value 'Absent') -eq 0) 'existing values suppressed'
    Check ((Value 'Nested\New') -eq 0) 'nested app id suppressed'
    Check (-not (Has-Banner 'Nested')) 'nested path container is untouched'
    Check ((Value 'WrongType') -ceq 'keep') 'non-DWORD setting is untouched'
    Check (-not (Has-Banner 'Keep') -and -not (Has-Banner 'Windows.SystemToast.Sample') -and
        -not (Has-Banner 'Windows.Defender.SecurityCenter')) 'exclusions untouched'
    Check (Test-Path -LiteralPath $journal) 'journal exists before restoration'
    $edited = Key 'Edited' $true
    $edited.SetValue('ShowBanner', 2, [Microsoft.Win32.RegistryValueKind]::DWord)
    $edited.Close()
    Send $process '{"command":"configure","keep":["Keep","Present"]}'
    Check ((Value 'Edited') -eq 2) 'user edit is not overwritten on reconfiguration'
    Check ((Value 'Present') -eq 1) 'new exclusion restored'
    Send $process '{"command":"app","name":"Arrived"}'
    Check ((Value 'Arrived') -eq 0) 'new app suppressed'
    $process.Kill()
    $process.WaitForExit()
    $process.Dispose()
    $process = $null
    & $helper -StateDirectory $state -RegistryRoot $testRoot -Command Restore
    Check (-not (Has-Banner 'Absent') -and -not (Has-Banner 'Arrived')) 'absent values restored after crash'
    Check ((Value 'Present') -eq 1 -and (Value 'Edited') -eq 2) 'original and user-edited values preserved'
    Check (-not (Test-Path -LiteralPath $journal)) 'journal removed after recovery'

    $process = Start-Worker
    Send $process '{"command":"configure","keep":[]}'
    $process.StandardInput.WriteLine('{"command":"stop"}')
    $process.StandardInput.Flush()
    Check ($process.WaitForExit(30000) -and $process.ExitCode -eq 0) 'normal worker stop'
    $process.Dispose()
    $process = $null
    Check (-not (Has-Banner 'Absent') -and (Value 'Present') -eq 1 -and (Value 'Edited') -eq 2) 'normal stop restores exact values'
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($testRoot, $true)
    for ($i = 0; $i -lt 100; $i++) { $key = $root.CreateSubKey("Bulk$i"); $key.Close() }
    $root.Close()
    $process = Start-Worker
    $process.StandardInput.WriteLine('{"command":"configure","keep":[]}')
    $process.StandardInput.WriteLine('{"command":"stop"}')
    $process.StandardInput.Flush()
    Check ($process.WaitForExit(30000) -and $process.ExitCode -eq 0) 'stop interrupts the initial scan'
    $process.Dispose()
    $process = $null
    $remaining = @(0..99 | Where-Object { Has-Banner "Bulk$_" })
    Check ($remaining.Count -eq 0 -and -not (Test-Path -LiteralPath $journal)) 'interrupted scan restores all writes'
    [IO.File]::WriteAllText($journal, '{"version":99,"entries":[]}')
    $failed = $false
    try { & $helper -StateDirectory $state -RegistryRoot $testRoot -Command Restore }
    catch { $failed = $true }
    Check ($failed -and (Test-Path -LiteralPath $journal)) 'invalid journal is preserved'
    Write-Output "BANNER_SUPPRESSION_TEST_PASS checks=$checks"
} finally {
    if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
    $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($testBase, $true)
    if ($parent) {
        try {
            $parent.DeleteSubKeyTree($id, $false)
            $empty = $parent.SubKeyCount -eq 0 -and $parent.ValueCount -eq 0
        } finally { $parent.Close() }
        if ($empty) {
            $software = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software', $true)
            try { $software.DeleteSubKey('CaelestiaWindowsTest', $false) }
            finally { $software.Close() }
        }
    }
    if ((Split-Path -Leaf $state) -ceq "caelestia-banner-test-$id" -and (Test-Path -LiteralPath $state)) {
        Remove-Item -LiteralPath $state -Recurse -Force
    }
}
