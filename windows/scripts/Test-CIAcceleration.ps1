#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
$ci = Join-Path $repoRoot 'windows\ci'
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-ci-acceleration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$checks = 0
function Assert-Refused([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $Pattern) { throw "Expected refusal was not raised: $Name ($message)" }
    $script:checks++
}
try {
    # Hardware-derived parallelism: bounded by processors, 3 GiB per job and
    # the trusted fixture runner's 1-16 range; unmeasurable hardware refuses.
    foreach ($case in @(
        @{ cpu = 4; memory = 16GB; jobs = 4 },
        @{ cpu = 4; memory = 7GB; jobs = 2 },
        @{ cpu = 4; memory = (6GB - 1); jobs = 1 },
        @{ cpu = 4; memory = 6GB; jobs = 2 },
        @{ cpu = 64; memory = 512GB; jobs = 16 },
        @{ cpu = [int]::MaxValue; memory = [double]::MaxValue; jobs = 16 },
        @{ cpu = 16; memory = 63.6GB; jobs = 16 },
        @{ cpu = 1; memory = 1GB; jobs = 1 })) {
        $environment = Join-Path $root ('env-' + [guid]::NewGuid().ToString('N'))
        $null = & "$ci\Get-BuildJobs.ps1" -LogicalProcessors $case.cpu -MemoryBytes $case.memory -EnvironmentFile $environment
        $actual = (Get-Content -LiteralPath $environment -Raw).Trim()
        if ($actual -cne "BUILD_JOBS=$($case.jobs)") { throw "Incorrect build parallelism for $($case.cpu) CPUs: $actual" }
        $checks++
    }
    $environment = Join-Path $root 'refused-env'
    Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 0 -MemoryBytes 16GB -EnvironmentFile $environment } 'refusing to guess' 'zero processors'
    Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -MemoryBytes 0 -EnvironmentFile $environment } 'refusing to guess' 'zero memory'
    foreach ($invalid in @(-1, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity)) {
        Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -MemoryBytes $invalid -EnvironmentFile $environment } 'refusing to guess' "invalid memory $invalid"
    }
    if (Test-Path -LiteralPath $environment) { throw 'A refused parallelism measurement still wrote BUILD_JOBS.' }
    $checks++
    # Exercise the default discovery branch too, without assuming anything
    # about the machine running this SDK-free regression.
    function Get-CimInstance {
        param([string]$ClassName)
        if ($ClassName -cne 'Win32_ComputerSystem') { throw 'Unexpected hardware query.' }
        return [pscustomobject]@{ TotalPhysicalMemory = $fixtureMemory }
    }
    $fixtureMemory = 7GB
    $environment = Join-Path $root 'measured-env'
    $null = & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -EnvironmentFile $environment
    if ((Get-Content -LiteralPath $environment -Raw).Trim() -cne 'BUILD_JOBS=2') {
        throw 'The measured hardware path did not use the detected memory.'
    }
    $checks++
    $environment = Join-Path $root 'invalid-measured-env'
    foreach ($invalid in @($null, -1, [double]::NaN, [double]::PositiveInfinity)) {
        $fixtureMemory = $invalid
        Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -EnvironmentFile $environment } 'refusing to guess' "invalid measured memory $invalid"
    }
    if (Test-Path -LiteralPath $environment) { throw 'Invalid measured hardware still wrote BUILD_JOBS.' }
    $checks++
    # Optional sccache: an unavailable download must not fail the build, but a
    # corrupt archive (checksum), extraction or version failure still must.
    $prepare = "$ci\Prepare-Sccache.ps1"
    $archiveName = 'sccache-v0.15.0-x86_64-pc-windows-msvc.tar.gz'
    function Start-FakeRelease([byte[]]$Response) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $worker = [powershell]::Create()
        $null = $worker.AddScript({
            param($Listener, $Bytes)
            $client = $Listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $null = $stream.Read((New-Object byte[] 4096), 0, 4096)
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush()
            $client.Close()
            'served'
        }).AddArgument($listener).AddArgument($Response)
        [pscustomobject]@{ Listener = $listener; Worker = $worker; Handle = $worker.BeginInvoke()
            Url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)" }
    }
    function Stop-FakeRelease($Server) {
        $served = $Server.Handle.AsyncWaitHandle.WaitOne(10000)
        $Server.Listener.Stop()
        if ($served) { $null = $Server.Worker.EndInvoke($Server.Handle) } else { $null = $Server.Worker.Stop() }
        $Server.Worker.Dispose()
        return $served
    }
    function Invoke-Prepare([string]$Name, [string]$Url) {
        $tools = Join-Path $root "sccache-$Name"
        $environmentFile = Join-Path $root "sccache-$Name-github-env"
        $env:GITHUB_ENV = $environmentFile
        $global:LASTEXITCODE = 99
        $message = $null
        $output = @()
        try { $output = @(& $prepare -ToolRoot $tools -ReleaseBaseUrl $Url) } catch { $message = $_.Exception.Message }
        [pscustomobject]@{ Output = $output; Message = $message; ExitCode = $global:LASTEXITCODE
            EnvironmentFile = $environmentFile; Archive = Join-Path $tools "downloads/$archiveName" }
    }
    $savedGithubEnv = $env:GITHUB_ENV
    try {
        $closed = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $closed.Start(); $closedPort = $closed.LocalEndpoint.Port; $closed.Stop()
        $failures = @(
            @{ name = 'refused'; url = "http://127.0.0.1:$closedPort"; server = $null },
            @{ name = 'http-504'; server = (Start-FakeRelease ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 504 Gateway Timeout`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"))) },
            @{ name = 'truncated'; server = (Start-FakeRelease ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 1000`r`nConnection: close`r`n`r`nabcdefghij"))) })
        foreach ($case in $failures) {
            $url = if ($case.server) { $case.server.Url } else { $case.url }
            $result = Invoke-Prepare $case.name $url
            if ($case.server -and -not (Stop-FakeRelease $case.server)) { throw "The fake release server was never contacted: $($case.name)" }
            if ($result.Message) { throw "A failed sccache download must not fail the step ($($case.name)): $($result.Message)" }
            if ($result.ExitCode -ne 0) { throw "A failed sccache download must exit 0 ($($case.name)): $($result.ExitCode)" }
            if (@($result.Output) -cnotcontains '::warning::sccache download failed; building without the compiler cache.') {
                throw "A failed sccache download must write the Actions warning ($($case.name)): $($result.Output -join '|')"
            }
            if (@($result.Output).Count -ne 1) { throw "A failed sccache download must output no launcher path ($($case.name))." }
            if (Test-Path -LiteralPath $result.EnvironmentFile) { throw "A failed sccache download must not set CI_COMPILER_LAUNCHER ($($case.name))." }
            if (Test-Path -LiteralPath $result.Archive) { throw "A failed sccache download left an archive behind ($($case.name))." }
            $checks++
        }
        $server = Start-FakeRelease ([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 5`r`nConnection: close`r`n`r`nwrong"))
        $result = Invoke-Prepare 'checksum' $server.Url
        if (-not (Stop-FakeRelease $server)) { throw 'The fake release server was never contacted: checksum.' }
        if ($result.Message -cne 'sccache checksum mismatch.') { throw "A checksum mismatch must stay fatal: $($result.Message)" }
        if (Test-Path -LiteralPath $result.EnvironmentFile) { throw 'A checksum mismatch must not set CI_COMPILER_LAUNCHER.' }
        $checks++
        $source = Get-Content -LiteralPath $prepare -Raw
        foreach ($fatal in @('sccache checksum mismatch.', 'sccache extraction failed.', 'sccache version mismatch.')) {
            if ($source -notmatch ("throw '" + [regex]::Escape($fatal) + "'")) { throw "Prepare-Sccache.ps1 no longer throws: $fatal" }
        }
        if ($source -match "throw 'sccache download failed") { throw 'Prepare-Sccache.ps1 must not throw on a failed download.' }
        $checks++
    } finally {
        $env:GITHUB_ENV = $savedGithubEnv
        if (-not $savedGithubEnv) { Remove-Item Env:GITHUB_ENV -ErrorAction SilentlyContinue }
    }
    Write-Output "PASS CI acceleration: $checks build-parallelism and optional-sccache checks."
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-ci-acceleration-*') { throw 'Unsafe CI-acceleration fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
