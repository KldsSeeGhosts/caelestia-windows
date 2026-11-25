[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfileRoot,
    # Empty resolves windows/sources.lock.json's schemeCli revision.
    [string]$CliRevision = '',
    # Exact python.exe/py.exe path used by tests and support scenarios. Empty
    # uses only SystemRoot or Python registry discovery, never PATH.
    [string]$Python = '',
    # Verified local copy of the commit archive used by hermetic tests. Its
    # bytes still must match sources.lock.json exactly; this is never a trust
    # override, only a network avoidance path.
    [string]$CliArchive = '',
    [switch]$Force,
    # After a failed provision, do not retry (and block startup) for this long.
    [int]$RetryCooldownMinutes = 360,
    # Upper bound for each venv/pip step.
    [int]$StepTimeoutSeconds = 180,
    # Installer preparation may wait for another provisioner outside the
    # readiness budget. Starts pass 0 and fall back to the fixed palette.
    [int]$LockWaitSeconds = 0
)

# Provisions a profile-local Python runtime that generates Material You schemes
# with the real caelestia CLI package. Each dependency revision gets its own
# immutable generation under scheme\runtimes\; runtime.json is published
# atomically only after the generation verifies. Nothing is installed into the
# repository or the user's ordinary Python installation/profiles.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')

$pinnedRevision = Get-CaelestiaSchemeRevision $PSScriptRoot
if ($pinnedRevision -cnotmatch '^[a-f0-9]{40}$') {
    throw 'sources.lock.json does not pin the scheme CLI revision'
}
if ($CliRevision -and $CliRevision -cne $pinnedRevision) {
    throw 'The requested scheme CLI revision does not match sources.lock.json.'
}
$CliRevision = $pinnedRevision
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
$schemeRoot = Join-Path $ProfileRoot 'scheme'
$runtimesRoot = Join-Path $schemeRoot 'runtimes'
$statePath = Join-Path $schemeRoot 'provision-state.json'
$historyLog = Join-Path $schemeRoot 'provision.log'
$helperSource = Join-Path $PSScriptRoot 'scheme\win_scheme.py'
$shimSource = Join-Path $PSScriptRoot 'scheme\fcntl.py'
$requirements = Join-Path $PSScriptRoot 'scheme\requirements.lock.txt'
$provisionLog = ''
$staging = ''

# No machine path belongs in a log or warning: redaction is by pattern
# (Protect-CaelestiaText), so custom install, Python and temp paths are covered.
function Protect-Text([string]$Text) { return Protect-CaelestiaText $Text }

function Write-History([string]$Message) {
    try {
        New-Item -ItemType Directory -Force -Path $schemeRoot | Out-Null
        Add-Content -LiteralPath $historyLog -Value ("{0} {1}" -f (Get-Date).ToString('o'), (Protect-Text $Message)) -Encoding UTF8
    } catch { }
}

function Write-JsonAtomic([string]$Path, $Value) {
    $directory = [IO.Path]::GetDirectoryName($Path)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        for ($attempt = 0; ; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) {
                    [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
                } else {
                    [IO.File]::Move($temporary, $Path)
                }
                break
            } catch [IO.IOException] {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Milliseconds (25 -shl $attempt)
            }
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

# Runs a command with a hard time limit. Its output is redacted before it is
# written to the generation log.
function Invoke-Bounded([string]$File, [string[]]$Arguments, [string]$Step, [hashtable]$Environment = @{}) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # pip configuration is process-wide and user-controllable. Every child gets
    # a clean pip environment rather than mutating and restoring the caller's;
    # PIP_CONFIG_FILE=nul also ignores pip.ini and per-user pip config files.
    foreach ($name in @($info.EnvironmentVariables.Keys)) {
        if ($name -like 'PIP_*') { $info.EnvironmentVariables.Remove($name) }
    }
    $info.EnvironmentVariables['PIP_CONFIG_FILE'] = 'nul'
    $info.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
    foreach ($name in $Environment.Keys) { $info.EnvironmentVariables[$name] = [string]$Environment[$name] }
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($StepTimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        $script:failure = [ordered]@{ step = $Step; exitCode = 'timeout' }
        throw "$Step timed out after $StepTimeoutSeconds s (offline or slow network?)"
    }
    $text = ($outTask.GetAwaiter().GetResult() + "`n" + $errTask.GetAwaiter().GetResult()).Trim()
    $clean = Protect-Text $text
    if ($clean) { Add-Content -LiteralPath $provisionLog -Value "[$Step] $clean" }
    if ($process.ExitCode -ne 0) {
        $tail = ($clean -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | '
        $script:failure = [ordered]@{ step = $Step; exitCode = [string]$process.ExitCode }
        throw "$Step failed (exit $($process.ExitCode)): $tail"
    }
}

# Generation identity covers every input that goes into the generation (the
# CLI revision, requirements, helper and fcntl shim), not just the revision: a
# change to any of them must never mutate a generation a running shell may use.
$identity = Get-CaelestiaSchemeIdentity $PSScriptRoot $CliRevision
if (-not $identity) { throw 'the scheme runtime inputs are missing from this payload' }
$generationId = $identity.Id

function Write-Result([bool]$Available, [string]$Message, [string]$Generation = '', [bool]$InProgress = $false) {
    $python = ''
    $helper = ''
    if ($Available -and $Generation) {
        $root = Join-Path $runtimesRoot $Generation
        $python = Join-Path $root 'venv\Scripts\python.exe'
        $helper = Join-Path $root 'win_scheme.py'
    }
    [ordered]@{
        available = $Available
        revision = $CliRevision
        generation = $Generation
        python = $python
        helper = $helper
        message = $Message
        inProgress = $InProgress
    } | ConvertTo-Json -Compress
}

# A generation is reusable only when it was built from exactly the inputs
# computed now and its interpreter still runs.
function Test-RuntimeAt([string]$Root) {
    try {
        $record = Get-Content -LiteralPath (Join-Path $Root 'generation.json') -Raw | ConvertFrom-Json
        if ([string]$record.revision -ne $CliRevision -or [string]$record.identity -ne $identity.Id) { return $false }
        return (Test-CaelestiaSchemeHealth $Root)
    } catch {
        return $false
    }
}

$schemeLock = Enter-CaelestiaSchemeLock $ProfileRoot $LockWaitSeconds
if (-not $schemeLock) {
    Write-Result $false 'another scheme provisioning run is in progress' '' $true
    return
}
try {
    New-Item -ItemType Directory -Force -Path $schemeRoot | Out-Null

    # The system Python a bridge may need without a scheme runtime (Wallpaper
    # Engine discovery) is resolved here, with a time limit, and recorded in
    # runtime.json. Activation only reads it and never starts Python itself.
    if (-not (Get-CaelestiaSchemeInterpreter $ProfileRoot)) {
        $systemPython = Resolve-CaelestiaSystemPython
        if ($systemPython) { Set-CaelestiaSchemeInterpreter $ProfileRoot $systemPython }
    }

    # Reuse the newest verified generation built from exactly these inputs (the
    # published one, or a sibling from an earlier repair) instead of building
    # another. Nothing in it is touched, so a running shell keeps stable bytes;
    # a candidate that fails its check is revoked from runtime.json.
    if (-not $Force) {
        $existing = Get-CaelestiaVerifiedSchemeGeneration $ProfileRoot $CliRevision $identity.Id
        if ($existing) {
            $null = Publish-CaelestiaSchemeRuntime $ProfileRoot $CliRevision $existing.Directory.FullName
            Write-Result $true 'cached' $existing.Name
            return
        }
    }

    # A recent failure for this input set is not retried on every start (for
    # example while offline); -Force overrides.
    if (-not $Force -and (Test-Path -LiteralPath $statePath)) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($state.available -eq $false -and [string]$state.key -eq $generationId -and $state.attemptedAt) {
                $age = [DateTimeOffset]::UtcNow - (ConvertTo-CaelestiaStatusUtc $state.attemptedAt)
                if ($age.TotalMinutes -ge 0 -and $age.TotalMinutes -lt $RetryCooldownMinutes) {
                    Write-Result $false "retry suppressed for $([int]($RetryCooldownMinutes - $age.TotalMinutes)) more minutes after: $($state.message)"
                    return
                }
            }
        } catch { }
    }

    $publishedId = $generationId
    if ($Force -or (Test-Path -LiteralPath (Join-Path $runtimesRoot $publishedId))) {
        # Never mutate a published generation, even a broken one that may be
        # mapped into a live process. Build a sibling instead.
        $publishedId = $generationId + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    }

    New-Item -ItemType Directory -Force -Path $runtimesRoot | Out-Null
    $staging = Join-Path $runtimesRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    $provisionLog = Join-Path $staging 'provision.log'
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $venv = Join-Path $staging 'venv'
        $archiveSha256 = Get-CaelestiaSchemeArchiveSha256 $PSScriptRoot
        if ($archiveSha256 -cnotmatch '^[a-fA-F0-9]{64}$') { throw 'sources.lock.json does not pin the scheme CLI archive SHA-256' }
        $hostSpec = Resolve-CaelestiaPythonHost $Python
        if ($hostSpec.IsLauncher -and $env:PYLAUNCHER_ALLOW_INSTALL) {
            throw 'automatic Python installation must be disabled before using the Python launcher'
        }
        $venvPython = Join-Path $venv 'Scripts\python.exe'
        # Select a CPython minor version covered by scheme\requirements.lock.txt (3.11-3.14).
        $pythonPrefix = @()
        if ($hostSpec.IsLauncher) {
            $pySelector = ''
            foreach ($ver in @('-3.14', '-3.13', '-3.12', '-3.11')) {
                $probe = Invoke-CaelestiaBounded $hostSpec.Executable ($ver + ' -c "import sys"') 10
                if ($probe -and $probe.ExitCode -eq 0) { $pySelector = $ver; break }
            }
            if (-not $pySelector) { throw 'no registered CPython 3.11-3.14 interpreter is available to the Python launcher' }
            $pythonPrefix = @($pySelector)
        } else {
            $probe = Invoke-CaelestiaBounded $hostSpec.Executable '-c "import sys; raise SystemExit(0 if (3,11) <= sys.version_info[:2] < (3,15) else 1)"' 10
            if (-not $probe -or $probe.ExitCode -ne 0) { throw 'the selected Python interpreter is not CPython 3.11-3.14' }
        }
        $venvArguments = @($pythonPrefix) + @('-I', '-m', 'venv', $venv)
        Invoke-Bounded $hostSpec.Executable $venvArguments 'creating the virtual environment'
        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            throw 'could not create the profile-local virtual environment'
        }

        # Keep pip's download cache inside the isolated profile too. It is child
        # process state only; the caller's PIP_* environment is never mutated.
        $pipCache = Join-Path $ProfileRoot 'cache\pip'
        New-Item -ItemType Directory -Force -Path $pipCache | Out-Null
        $pipArguments = @('-I', '-m', 'pip', 'install', '--cache-dir', $pipCache, '--disable-pip-version-check',
            '--quiet', '--timeout', '30', '--retries', '1', '--no-deps')

        # Binary wheels only, each verified against the SHA-256 digests locked in
        # scheme\requirements.lock.txt. The lock includes the hatchling/hatch-vcs
        # build backend because pip no longer downloads a build backend in an
        # unhashed isolated environment.
        Invoke-Bounded $venvPython ($pipArguments + @('--only-binary=:all:', '--require-hashes', '-r', $requirements)) 'installing locked Python wheels'

        # Download the commit-addressed source archive and verify its pinned
        # digest before pip sees it. Installing that verified archive with
        # --no-build-isolation removes both the runtime git dependency and the
        # unhashed build-backend download.
        $archive = Join-Path $staging 'caelestia-cli.tar.gz'
        $archiveUrl = 'https://github.com/caelestia-dots/cli/archive/' + $CliRevision + '.tar.gz'
        try {
            if ($CliArchive) {
                $archiveInput = [IO.Path]::GetFullPath($CliArchive)
                if (-not (Test-Path -LiteralPath $archiveInput -PathType Leaf)) { throw "archive override does not exist: $CliArchive" }
                Copy-Item -LiteralPath $archiveInput -Destination $archive -Force
            } else {
                Invoke-WebRequest -Uri $archiveUrl -OutFile $archive -UseBasicParsing -TimeoutSec 60
            }
        } catch {
            $script:failure = [ordered]@{ step = 'obtaining the pinned caelestia CLI archive'; exitCode = 'network' }
            throw "obtaining the pinned caelestia CLI archive failed: $($_.Exception.Message)"
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveSha256) {
            $script:failure = [ordered]@{ step = 'verifying the pinned caelestia CLI archive'; exitCode = 'sha256' }
            throw 'the downloaded caelestia CLI archive does not match its pinned SHA-256'
        }
        # GitHub archives intentionally omit .git. This exact, public version is
        # metadata only; the commit id and archive digest above remain the
        # provenance and integrity checks.
        $cliEnvironment = @{ SETUPTOOLS_SCM_PRETEND_VERSION = '0.0.0+git' + $CliRevision.Substring(0, 12) }
        Invoke-Bounded $venvPython ($pipArguments + @('--no-build-isolation', '--ignore-requires-python', $archive)) "installing the caelestia CLI at $CliRevision" $cliEnvironment

        Copy-Item -LiteralPath $helperSource -Destination (Join-Path $staging 'win_scheme.py') -Force
        # CPython creates this directory on Windows. Avoid round-tripping the
        # path through Python's console encoding, which can mangle non-ASCII.
        $shimDir = Join-Path $venv 'Lib\site-packages'
        Copy-Item -LiteralPath $shimSource -Destination (Join-Path $shimDir 'fcntl.py') -Force

        # The bridge never applies upstream themes, but keep a profile-local CLI
        # config that disables every Linux theme writer in case the CLI is run by
        # hand from this environment.
        $cliConfigDir = Join-Path $ProfileRoot 'config\caelestia'
        New-Item -ItemType Directory -Force -Path $cliConfigDir | Out-Null
        $cliConfig = Join-Path $cliConfigDir 'cli.json'
        if (-not (Test-Path -LiteralPath $cliConfig)) {
            @'
{"theme":{"enableTerm":false,"enableHypr":false,"enableDiscord":false,"enableSpicetify":false,"enablePandora":false,"enableFuzzel":false,"enableBtop":false,"enableNvtop":false,"enableHtop":false,"enableGtk":false,"enableQt":false,"enableWarp":false,"enableChromium":false,"enableZed":false,"enableCava":false}}
'@ | Set-Content -LiteralPath $cliConfig -Encoding UTF8
        }

        [ordered]@{
            revision = $CliRevision
            generation = $publishedId
            created = (Get-Date).ToString('o')
            identity = $identity.Id
            requirementsSha256 = $identity.RequirementsSha256
            helperSha256 = $identity.HelperSha256
            shimSha256 = $identity.ShimSha256
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'generation.json') -Encoding UTF8

        if (-not (Test-RuntimeAt $staging)) {
            throw 'the installed runtime cannot import materialyoucolor/PIL/caelestia'
        }

        $target = Join-Path $runtimesRoot $publishedId
        if (Test-Path -LiteralPath $target) {
            throw 'another process published this scheme runtime generation'
        }
        [IO.Directory]::Move($staging, $target)
        $staging = ''

        if (-not (Publish-CaelestiaSchemeRuntime $ProfileRoot $CliRevision $target)) {
            throw 'could not record the verification of the new runtime'
        }
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-History "READY revision $CliRevision generation $publishedId"
        Write-Result $true 'provisioned' $publishedId
    } catch {
        $message = Protect-Text $_.Exception.Message
        # The step and exit code are fields of their own, so redacting a path in
        # the tool output can never drop them.
        $failedStep = if ($script:failure) { [string]$script:failure.step } else { '' }
        $failedExit = if ($script:failure) { [string]$script:failure.exitCode } else { '' }
        Write-History "FAILED step=$failedStep exit=$failedExit : $message"
        Write-Warning "Scheme runtime unavailable: $message"
        Write-JsonAtomic $statePath ([ordered]@{
            available = $false
            revision = $CliRevision
            key = $generationId
            generation = $publishedId
            step = $failedStep
            exitCode = $failedExit
            message = $message
            attemptedAt = (Get-Date).ToString('o')
        })
        if ($staging -and (Test-Path -LiteralPath $staging)) {
            try {
                $safe = Resolve-CaelestiaDirectory $staging
                if ((Split-Path -Parent $safe) -eq $runtimesRoot.TrimEnd('\') -and (Split-Path -Leaf $safe) -like '.staging-*') {
                    Assert-CaelestiaNoReparsePoints $safe
                    Remove-Item -LiteralPath $safe -Recurse -Force
                }
            } catch { }
        }
        Write-Result $false $message
    }
} finally {
    Exit-CaelestiaSchemeLock $schemeLock
}
