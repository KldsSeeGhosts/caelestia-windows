param([string]$Common, [string]$Child, [string]$Marker, [switch]$AllowBreakaway)
$ErrorActionPreference = 'Stop'
. $Common
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class LaunchJobFixture {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr info, uint length, IntPtr returned);
    // True when an enclosing job (for example a hosted CI runner's) forbids
    // breakaway, so no nested job can grant it.
    public static bool OuterJobForbidsBreakaway() {
        bool inJob;
        if (!IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out inJob)) throw new Win32Exception();
        if (!inJob) return false;
        const int size = 144;
        var info = Marshal.AllocHGlobal(size);
        try {
            Marshal.Copy(new byte[size], 0, info, size);
            if (!QueryInformationJobObject(IntPtr.Zero, 9, info, size, IntPtr.Zero)) throw new Win32Exception();
            return (Marshal.ReadInt32(info, 16) & (0x800 | 0x1000)) == 0;
        } finally {
            Marshal.FreeHGlobal(info);
        }
    }
    public static void Enter(bool allowBreakaway) {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();
        // JOBOBJECT_EXTENDED_LIMIT_INFORMATION on Windows x64. LimitFlags
        // follows the two 64-bit time fields in BasicLimitInformation.
        const int size = 144;
        var info = Marshal.AllocHGlobal(size);
        bool assigned = false;
        try {
            Marshal.Copy(new byte[size], 0, info, size);
            Marshal.WriteInt32(info, 16, 0x2000 | (allowBreakaway ? 0x800 : 0));
            if (!SetInformationJobObject(job, 9, info, size) || !AssignProcessToJobObject(job, GetCurrentProcess()))
                throw new Win32Exception();
            assigned = true;
        } finally {
            Marshal.FreeHGlobal(info);
            if (!assigned) CloseHandle(job);
        }
        // This test process owns the sole handle until exit.
    }
}
'@
if ($AllowBreakaway -and [LaunchJobFixture]::OuterJobForbidsBreakaway()) {
    'LAUNCH-JOB-SKIP: an enclosing job forbids breakaway, so the allowed case cannot be exercised here.'
    'LAUNCH-JOB-PASS'
    exit 0
}
[LaunchJobFixture]::Enter($AllowBreakaway.IsPresent)
$childProcess = $null
$refusal = ''
try {
    $childProcess = Start-CaelestiaOutOfJobProcess (Get-CaelestiaPowerShellPath) `
        ('-NoProfile -NonInteractive -File "' + $Child + '" -Marker "' + $Marker + '"') $env:USERPROFILE
} catch { $refusal = $_.Exception.Message }
if (-not $AllowBreakaway) {
    if ($childProcess -or $refusal -notmatch 'outside this job' -or (Test-Path -LiteralPath $Marker)) {
        throw 'The blocked job ran its child or lost the actionable refusal.'
    }
} else {
    if (-not $childProcess) { throw $refusal }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $Marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-Path -LiteralPath $Marker) -or $childProcess.HasExited) { throw 'The detached child did not start and stay alive.' }
        $childProcess.Kill()
        if (-not $childProcess.WaitForExit(5000) -or -not $childProcess.HasExited) { throw 'Cleanup through the original process handle failed.' }
    } finally { $childProcess.Dispose() }
}
'LAUNCH-JOB-PASS'
