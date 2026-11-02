# Keeps the Windows display and system awake for as long as this process lives.
#
# Windows has no freedesktop idle-inhibition protocol. SetThreadExecutionState
# is per-thread and is cleared when the thread exits, so the shell starts one
# helper and keeps it alive while the toggle is on. Turning the toggle off
# terminates the helper (Quickshell kills its child processes), and the helper
# also exits by itself when the shell PID is gone. Either way the execution
# state disappears with the thread that requested it.
[CmdletBinding()]
param(
    # Shell PID to watch. When omitted the parent PID is resolved below.
    [int]$ParentProcessId = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CaelestiaPower
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@

# ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
$ES_CONTINUOUS = [uint32]2147483648
$flags = [uint32](2147483648 -bor 1 -bor 2)

if ($ParentProcessId -le 0) {
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if ($process -and $process.ParentProcessId) {
        $ParentProcessId = [int]$process.ParentProcessId
    }
}

$previous = [CaelestiaPower]::SetThreadExecutionState($flags)
if ($previous -eq 0) {
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [Console]::Error.WriteLine("SetThreadExecutionState failed with Win32 error $code.")
    exit 1
}

try {
    while ($true) {
        Start-Sleep -Seconds 2
        if ($ParentProcessId -gt 0 -and -not (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)) {
            break
        }
    }
} finally {
    [void][CaelestiaPower]::SetThreadExecutionState($ES_CONTINUOUS)
}
