[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Compile the production file alone exactly as Watch-DesktopShell.ps1 does.
& "$PSHOME\powershell.exe" -NoProfile -Command `
    "Add-Type -Path '$($PSScriptRoot.Replace("'", "''"))\DesktopTakeover.cs' -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions"
if ($LASTEXITCODE -ne 0) { throw 'Production Add-Type compilation failed.' }
# Compile the same source together with the fake harness. This process does not
# call Supervisor.Run, SetWinEventHook, ShowWindow, or any desktop operation.
# Snapshot persistence is exercised using an isolated temporary file.
Add-Type -Path @((Join-Path $PSScriptRoot 'DesktopTakeover.cs'),
    (Join-Path $PSScriptRoot 'TaskbarEvents.Tests.cs')) `
    -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
$count = [TaskbarEventsTests]::Run()
Write-Output "PASS taskbar event and shortcut logic: $count assertions; production Add-Type compilation passed."
