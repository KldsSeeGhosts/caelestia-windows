[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfileRoot,
    # Empty resolves windows/sources.lock.json's schemeCli revision.
    [string]$CliRevision = '',
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

if (-not $CliRevision) {
    $CliRevision = Get-CaelestiaSchemeRevision $PSScriptRoot
    if (-not $CliRevision) {
        throw 'sources.lock.json does not pin the scheme CLI revision'
    }
}
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
$schemeRoot = Join-Path $ProfileRoot 'scheme'
$runtimesRoot = Join-Path $schemeRoot 'runtimes'
$stamp = Join-Path $schemeRoot 'runtime.json'
$statePath = Join-Path $schemeRoot 'provision-state.json'
$historyLog = Join-Path $schemeRoot 'provision.log'
$helperSource = Join-Path $PSScriptRoot 'scheme\win_scheme.py'
$shimSource = Join-Path $PSScriptRoot 'scheme\fcntl.py'
$requirements = Join-Path $PSScriptRoot 'scheme\requirements.lock.txt'
$provisionLog = ''
$staging = ''

# No profile or user path belongs in a log or warning.
function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    $clean = $Text
    foreach ($pair in @(
        @($ProfileRoot, '<profile>'),
        @($env:USERPROFILE, '<user>'),
        @($env:LOCALAPPDATA, '<localappdata>')
    )) {
        if ($pair[0]) {
            $clean = [regex]::Replace($clean, [regex]::Escape([string]$pair[0]), $pair[1],
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    return $clean
}

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
function Invoke-Bounded([string]$File, [string[]]$Arguments, [string]$Step) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($StepTimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "$Step timed out after $StepTimeoutSeconds s (offline or slow network?)"
    }
    $text = ($outTask.GetAwaiter().GetResult() + "`n" + $errTask.GetAwaiter().GetResult()).Trim()
    $clean = Protect-Text $text
    if ($clean) { Add-Content -LiteralPath $provisionLog -Value "[$Step] $clean" }
    if ($process.ExitCode -ne 0) {
        $tail = ($clean -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | '
        throw "$Step failed (exit $($process.ExitCode)): $tail"
    }
}

function Get-FileHashHex([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Generation identity covers every input that can change the installed bytes,
# not just the CLI revision: a helper or requirements change must never mutate
# a generation a running shell may still be using.
function Get-GenerationId {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $material = $CliRevision + "`n" +
            (Get-FileHashHex $requirements) + "`n" +
            (Get-FileHashHex $helperSource) + "`n" +
            (Get-FileHashHex $shimSource)
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

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

function Test-RuntimeAt([string]$Root, [string]$ExpectedGeneration = '') {
    $python = Join-Path $Root 'venv\Scripts\python.exe'
    $helper = Join-Path $Root 'win_scheme.py'
    $meta = Join-Path $Root 'generation.json'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or
        -not (Test-Path -LiteralPath $helper -PathType Leaf) -or
        -not (Test-Path -LiteralPath $meta -PathType Leaf)) {
        return $false
    }
    try {
        $record = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
        if ([string]$record.revision -ne $CliRevision) { return $false }
        if ([string]$record.requirementsSha256 -ne (Get-FileHashHex $requirements) -or
            [string]$record.helperSha256 -ne (Get-FileHashHex $helperSource)) { return $false }
        if ($ExpectedGeneration -and [string]$record.generation -ne $ExpectedGeneration) { return $false }
        $previousBytecode = $env:PYTHONDONTWRITEBYTECODE
        $env:PYTHONDONTWRITEBYTECODE = '1'
        try {
            $null = & $python -c "import materialyoucolor, PIL, caelestia" 2>$null
            return $LASTEXITCODE -eq 0
        } finally {
            $env:PYTHONDONTWRITEBYTECODE = $previousBytecode
        }
    } catch {
        return $false
    }
}

$generationId = Get-GenerationId
$schemeLock = Enter-CaelestiaSchemeLock $ProfileRoot $LockWaitSeconds
if (-not $schemeLock) {
    Write-Result $false 'another scheme provisioning run is in progress' '' $true
    return
}
try {
    New-Item -ItemType Directory -Force -Path $schemeRoot | Out-Null

    # A published generation for this exact revision and input set is reused
    # read-only. Nothing in it is touched, so a running shell keeps stable bytes.
    if (-not $Force -and (Test-Path -LiteralPath $stamp)) {
        try {
            $record = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
            if ($record.available -eq $true -and [string]$record.revision -eq $CliRevision -and
                (Test-CaelestiaSchemeGeneration ([string]$record.generation))) {
                $publishedRoot = Join-Path $runtimesRoot ([string]$record.generation)
                if (Test-RuntimeAt $publishedRoot ([string]$record.generation)) {
                    Write-Result $true 'cached' ([string]$record.generation)
                    return
                }
            }
        } catch {
            # A corrupt marker falls through to a fresh generation.
        }
    }

    # A recent failure for this input set is not retried on every start (for
    # example while offline); -Force overrides.
    if (-not $Force -and (Test-Path -LiteralPath $statePath)) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($state.available -eq $false -and [string]$state.key -eq $generationId -and $state.attemptedAt) {
                $age = (Get-Date) - [DateTime]::Parse([string]$state.attemptedAt)
                if ($age.TotalMinutes -ge 0 -and $age.TotalMinutes -lt $RetryCooldownMinutes) {
                    Write-Result $false "retry suppressed for $([int]($RetryCooldownMinutes - $age.TotalMinutes)) more minutes after: $($state.message)"
                    return
                }
            }
        } catch { }
    }

    $publishedId = $generationId
    if (-not $Force -and (Test-Path -LiteralPath (Join-Path $runtimesRoot $publishedId))) {
        if (Test-RuntimeAt (Join-Path $runtimesRoot $publishedId) $publishedId) {
            Write-JsonAtomic $stamp ([ordered]@{
                available = $true
                revision = $CliRevision
                generation = $publishedId
                python = (Join-Path (Join-Path $runtimesRoot $publishedId) 'venv\Scripts\python.exe')
                helper = (Join-Path (Join-Path $runtimesRoot $publishedId) 'win_scheme.py')
                provisionedAt = (Get-Date).ToString('o')
            })
            Write-Result $true 'cached' $publishedId
            return
        }
        # Never mutate a published generation, even a broken one that may be
        # mapped into a live process. Build a sibling instead.
        $publishedId = $generationId + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    } elseif ($Force) {
        $publishedId = $generationId + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    }

    New-Item -ItemType Directory -Force -Path $runtimesRoot | Out-Null
    $staging = Join-Path $runtimesRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    $provisionLog = Join-Path $staging 'provision.log'
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $venv = Join-Path $staging 'venv'
        $python = Join-Path $venv 'Scripts\python.exe'
        $launcher = Get-Command py -ErrorAction SilentlyContinue
        if (-not $launcher) {
            throw 'the Python launcher (py) is not on PATH'
        }
        # Select a CPython minor version covered by scheme\requirements.lock.txt (3.11-3.14).
        $pySelector = '-3'
        foreach ($ver in @('-3.14', '-3.13', '-3.12', '-3.11')) {
            try {
                $null = & $launcher.Source $ver -c "import sys" 2>$null
                if ($LASTEXITCODE -eq 0) { $pySelector = $ver; break }
            } catch { }
        }
        Invoke-Bounded $launcher.Source @($pySelector, '-m', 'venv', $venv) 'creating the virtual environment'
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw 'could not create the profile-local virtual environment'
        }

        # Keep pip's download cache inside the isolated profile too.
        $env:PIP_CACHE_DIR = Join-Path $ProfileRoot 'cache\pip'
        New-Item -ItemType Directory -Force -Path $env:PIP_CACHE_DIR | Out-Null

        # Binary wheels only, each verified against the SHA-256 digests locked in
        # scheme\requirements.lock.txt. The CLI declares Python >= 3.13; only its
        # packaging metadata needs that. The scheme/material modules run on 3.12.
        Invoke-Bounded $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--timeout', '30', '--retries', '1', '--no-deps', '--only-binary=:all:', '--require-hashes', '-r', $requirements) 'installing materialyoucolor/pillow'
        # The commit id in the URL content-addresses the CLI source (git verifies it).
        Invoke-Bounded $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--timeout', '30', '--retries', '1', '--no-deps', '--ignore-requires-python', "git+https://github.com/caelestia-dots/cli@$CliRevision") "installing the caelestia CLI at $CliRevision"

        Copy-Item -LiteralPath $helperSource -Destination (Join-Path $staging 'win_scheme.py') -Force
        $shimDir = (& $python -c "import site; print(site.getsitepackages()[0])" 2>$null | Select-Object -First 1)
        if ($shimDir) {
            New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
            Copy-Item -LiteralPath $shimSource -Destination (Join-Path $shimDir 'fcntl.py') -Force
        }

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
            requirementsSha256 = (Get-FileHashHex $requirements)
            helperSha256 = (Get-FileHashHex $helperSource)
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'generation.json') -Encoding UTF8

        if (-not (Test-RuntimeAt $staging $publishedId)) {
            throw 'the installed runtime cannot import materialyoucolor/PIL/caelestia'
        }

        $target = Join-Path $runtimesRoot $publishedId
        if (Test-Path -LiteralPath $target) {
            throw 'another process published this scheme runtime generation'
        }
        [IO.Directory]::Move($staging, $target)
        $staging = ''

        Write-JsonAtomic $stamp ([ordered]@{
            available = $true
            revision = $CliRevision
            generation = $publishedId
            python = (Join-Path $target 'venv\Scripts\python.exe')
            helper = (Join-Path $target 'win_scheme.py')
            provisionedAt = (Get-Date).ToString('o')
        })
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-History "READY revision $CliRevision generation $publishedId"
        Write-Result $true 'provisioned' $publishedId
    } catch {
        $message = Protect-Text $_.Exception.Message
        Write-History "FAILED: $message"
        Write-Warning "Scheme runtime unavailable: $message"
        Write-JsonAtomic $statePath ([ordered]@{
            available = $false
            revision = $CliRevision
            key = $generationId
            generation = $publishedId
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
