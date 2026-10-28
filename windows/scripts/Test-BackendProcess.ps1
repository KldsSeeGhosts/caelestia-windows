[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-process-test-' + [guid]::NewGuid().ToString('N'))
$helperDir = Join-Path $root 'helper'
$appDir = Join-Path $root 'app'
New-Item -ItemType Directory -Path $root, $helperDir, $appDir | Out-Null
$fixture = Join-Path $root 'holder.exe'
$launcher = Join-Path $root 'launcher.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'SupervisorPipeFixture.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$env:PATH = "$(Split-Path -Parent $vswhere);$env:PATH"
& (Join-Path $vsRoot 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$env:PATH = "$LlvmBin;$QtPrefix\bin;$env:PATH"
$backend = Join-Path $PSScriptRoot '..\deps\quickshell\src\io\processcore.cpp'
Push-Location $root
try {
    & (Join-Path $LlvmBin 'clang-cl.exe') /nologo /EHsc /std:c++20 /MD `
        "/I$QtPrefix\include" "/I$QtPrefix\include\QtCore" "/I$QtPrefix\include\QtQmlIntegration" `
        (Join-Path $PSScriptRoot 'BackendProcessFixture.cpp') $backend "/Fe:$launcher" `
        /link "/LIBPATH:$QtPrefix\lib" Qt6Core.lib
    if ($LASTEXITCODE -ne 0) { throw 'Backend process fixture compilation failed.' }
} finally { Pop-Location }
$info = [Diagnostics.ProcessStartInfo]::new($launcher)
$info.Arguments = '"' + $fixture + '" "' + $helperDir + '" "' + $appDir + '"'
$info.WorkingDirectory = $root
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $helperMarker = Get-ChildItem -LiteralPath $helperDir -Filter 'holder-*' | Select-Object -First 1
        $appMarker = Get-ChildItem -LiteralPath $appDir -Filter 'holder-*' | Select-Object -First 1
        if ($helperMarker -and $appMarker) { break }
        if ($process.HasExited) { throw "Backend fixture exited early with code $($process.ExitCode)." }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $helperMarker -or -not $appMarker) { throw 'Backend fixture did not start both processes.' }
    $helperPid = [int](Get-Content -LiteralPath $helperMarker.FullName -Raw)
    $appPid = [int](Get-Content -LiteralPath $appMarker.FullName -Raw)
    $process.Kill()
    if (-not $process.WaitForExit(5000)) { throw 'Fixture did not exit.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((Get-Process -Id $helperPid -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (Get-Process -Id $helperPid -ErrorAction SilentlyContinue) { throw 'Attached helper survived shell death.' }
    if (-not (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) { throw 'Detached application was killed.' }
    if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Detached application retained the redirected pipe.' }
    Write-Output 'PASS backend process lifetime: helper died, detached app survived, and both shell pipes reached EOF.'
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
    $process.Dispose()
    foreach ($marker in @(Get-ChildItem -LiteralPath $root -Filter 'holder-*' -Recurse)) {
        $pidToStop = [int](Get-Content -LiteralPath $marker.FullName -Raw)
        $holder = Get-Process -Id $pidToStop -ErrorAction SilentlyContinue
        if ($holder -and $holder.Path -eq $fixture) { $holder.Kill(); $holder.WaitForExit(5000) | Out-Null }
    }
}
