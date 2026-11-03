[CmdletBinding()]
param()
# Isolated stub processes only. Never runs the installed Glazier, never
# touches a real prefix, and every temporary path is created under TEMP.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$root = Resolve-CaelestiaDirectory (Join-Path $env:TEMP ('caelestia-installer-host-test-' + [guid]::NewGuid().ToString('N')))
[IO.Directory]::CreateDirectory($root) | Out-Null
$stub = Join-Path $root 'window-stub.exe'
Add-Type -Path (Join-Path $repo 'windows\glazier\GlazierWindowStub.cs') -OutputAssembly $stub -OutputType WindowsApplication

function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Start-Stub([string]$Exe, [string]$Closed, [string]$PidFile) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['GLAZIER_WINDOW_CLOSED'] = $Closed
    $info.EnvironmentVariables['GLAZIER_WINDOW_PID'] = $PidFile
    return [Diagnostics.Process]::Start($info)
}
function Wait-Stub([string]$PidFile) {
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path -LiteralPath $PidFile) { return }
        Start-Sleep -Milliseconds 50
    }
    throw "The stub did not create its window: $PidFile"
}
try {
    $prefix = Join-Path $root 'prefix'
    $retiredVersion = Join-Path $prefix 'versions\v-retired'
    $currentVersion = Join-Path $prefix 'versions\v-current'
    $other = Join-Path $root 'other'
    foreach ($dir in @($retiredVersion, $currentVersion, $other)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
    $retiredHost = Join-Path $retiredVersion 'glazier.exe'
    $currentHost = Join-Path $currentVersion 'glazier.exe'
    $otherHost = Join-Path $other 'glazier.exe'
    foreach ($file in @($retiredHost, $currentHost, $otherHost)) { Copy-Item -LiteralPath $stub -Destination $file }

    $retiredPid = Join-Path $root 'retired-pid.txt'
    $retiredClosed = Join-Path $root 'retired-closed.txt'
    $currentPid = Join-Path $root 'current-pid.txt'
    $currentClosed = Join-Path $root 'current-closed.txt'
    $otherPid = Join-Path $root 'other-pid.txt'
    $otherClosed = Join-Path $root 'other-closed.txt'
    $retiredProcess = Start-Stub $retiredHost $retiredClosed $retiredPid
    $currentProcess = Start-Stub $currentHost $currentClosed $currentPid
    $otherProcess = Start-Stub $otherHost $otherClosed $otherPid
    try {
        Wait-Stub $retiredPid
        Wait-Stub $currentPid
        Wait-Stub $otherPid
        $found = @(Get-CaelestiaHostProcesses $prefix)
        Assert ($found.Count -eq 2 -and
            @($found | Where-Object { $_.Id -in @($retiredProcess.Id, $currentProcess.Id) }).Count -eq 2) `
            'Both payload hosts were not selected.'
        Stop-CaelestiaHosts $prefix $retiredVersion
        Assert ($retiredProcess.WaitForExit(5000)) 'The retired payload host was not stopped.'
        Assert (Test-Path -LiteralPath $retiredClosed) 'The retired payload host was not closed gracefully.'
        Assert (-not $currentProcess.HasExited) 'Stopping a retired payload stopped the current host.'
        Assert (-not $otherProcess.HasExited) 'A host outside the prefix was stopped.'

        Stop-CaelestiaHosts $prefix
        Assert ($currentProcess.WaitForExit(5000)) 'The current payload host was not stopped.'
        Assert (Test-Path -LiteralPath $currentClosed) 'The current payload host was not closed gracefully.'
        Assert (-not $otherProcess.HasExited) 'A host outside the prefix was stopped by the prefix-wide stop.'
        Write-Output 'INSTALLER_HOST_PASS'
    } finally {
        foreach ($entry in @(
                @{ Process = $retiredProcess; Pid = $retiredPid },
                @{ Process = $currentProcess; Pid = $currentPid },
                @{ Process = $otherProcess; Pid = $otherPid })) {
            if (-not $entry.Process.HasExited) {
                & taskkill.exe /PID $entry.Process.Id 2>&1 | Out-Null
                $null = $entry.Process.WaitForExit(5000)
            }
            $entry.Process.Dispose()
        }
    }
} finally {
    $safe = Resolve-CaelestiaDirectory $root
    if ((Split-Path -Parent $safe) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or
        (Split-Path -Leaf $safe) -notlike 'caelestia-installer-host-test-*') { throw 'Unsafe test cleanup.' }
    Assert-CaelestiaNoReparsePoints $safe
    Remove-Item -LiteralPath $safe -Recurse -Force
}
