[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfileRoot,
    # Empty resolves windows/sources.lock.json's schemeCli revision.
    [string]$CliRevision = '',
    [switch]$Force,
    # After a failed provision, do not retry (and block startup) for this long.
    [int]$RetryCooldownMinutes = 360,
    # Upper bound for each venv/pip step.
    [int]$StepTimeoutSeconds = 180
)

# Provisions the profile-local Python runtime that generates Material You
# schemes with the real caelestia CLI package. Nothing is installed into the
# repository or the user's ordinary Python installation/profiles. A failure is
# reported as available=false so the shell still starts with its fixed palette.
$ErrorActionPreference = 'Stop'
if (-not $CliRevision) {
    $lockPath = Join-Path $PSScriptRoot '..\sources.lock.json'
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) {
        $lockPath = Join-Path $PSScriptRoot 'licenses\sources.lock.json'
    }
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $CliRevision = [string]$lock.schemeCli.revision
    if (-not $CliRevision) {
        throw 'sources.lock.json does not pin the scheme CLI revision'
    }
}
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
$runtimeRoot = Join-Path $ProfileRoot 'scheme'
$venv = Join-Path $runtimeRoot 'venv'
$python = Join-Path $venv 'Scripts\python.exe'
$helperSource = Join-Path $PSScriptRoot 'scheme\win_scheme.py'
$helper = Join-Path $runtimeRoot 'win_scheme.py'
$shimSource = Join-Path $PSScriptRoot 'scheme\fcntl.py'
$stamp = Join-Path $runtimeRoot 'runtime.json'
$requirements = Join-Path $PSScriptRoot 'scheme\requirements.lock.txt'
$provisionLog = Join-Path $runtimeRoot 'provision.log'

# Runs a command with a hard time limit; returns its exit code and output.
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
    if ($text) { Add-Content -LiteralPath $provisionLog -Value "[$Step] $text" }
    if ($process.ExitCode -ne 0) {
        $tail = ($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | '
        throw "$Step failed (exit $($process.ExitCode)): $tail"
    }
}

function Write-Result([bool]$Available, [string]$Message) {
    [ordered]@{
        available = $Available
        python = $(if (Test-Path -LiteralPath $python) { $python } else { '' })
        helper = $(if (Test-Path -LiteralPath $helper) { $helper } else { '' })
        revision = $CliRevision
        message = $Message
    } | ConvertTo-Json -Compress
}

function Test-Runtime {
    if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $helper)) {
        return $false
    }
    try {
        & $python -c "import materialyoucolor, PIL, caelestia" 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
if (-not $Force -and (Test-Path -LiteralPath $stamp)) {
    try {
        $record = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
        if ($record.available -eq $true -and $record.revision -eq $CliRevision -and (Test-Runtime)) {
            Copy-Item -LiteralPath $helperSource -Destination $helper -Force
            $shimDir = (& $python -c "import site; print(site.getsitepackages()[0])" 2>$null | Select-Object -First 1)
            if ($shimDir) {
                Copy-Item -LiteralPath $shimSource -Destination (Join-Path $shimDir 'fcntl.py') -Force
            }
            Write-Result $true 'cached'
            return
        }
        # A recent failure for this revision is not retried synchronously on
        # every start (for example while offline); -Force overrides.
        if ($record.available -eq $false -and $record.revision -eq $CliRevision -and $record.attemptedAt) {
            $age = (Get-Date) - [DateTime]::Parse([string]$record.attemptedAt)
            if ($age.TotalMinutes -ge 0 -and $age.TotalMinutes -lt $RetryCooldownMinutes) {
                Write-Result $false "retry suppressed for $([int]($RetryCooldownMinutes - $age.TotalMinutes)) more minutes after: $($record.message)"
                return
            }
        }
    } catch {
        # A corrupt marker falls through to a fresh provision.
    }
}

Write-Host 'Provisioning the profile-local scheme runtime.'
try {
    if (-not (Test-Path -LiteralPath $python)) {
        $launcher = Get-Command py -ErrorAction SilentlyContinue
        if (-not $launcher) {
            throw 'the Python launcher (py) is not on PATH'
        }
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        # Select a CPython minor version covered by scheme\requirements.lock.txt (3.11-3.14).
        $pySelector = '-3'
        foreach ($ver in @('-3.14', '-3.13', '-3.12', '-3.11')) {
            try {
                $null = & $launcher.Source $ver -c "import sys" 2>$null
                if ($LASTEXITCODE -eq 0) { $pySelector = $ver; break }
            } catch { }
        }
        Invoke-Bounded $launcher.Source @($pySelector, '-m', 'venv', $venv) 'creating the virtual environment'
        if (-not (Test-Path -LiteralPath $python)) {
            throw 'could not create the profile-local virtual environment'
        }
    }

    # Keep pip's download cache inside the isolated profile too.
    $env:PIP_CACHE_DIR = Join-Path $ProfileRoot 'cache\pip'

    # Binary wheels only, each verified against the SHA-256 digests locked in
    # scheme\requirements.lock.txt. The CLI declares Python >= 3.13; only its
    # packaging metadata needs that. The scheme/material modules run on 3.12.
    Invoke-Bounded $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--timeout', '30', '--retries', '1', '--no-deps', '--only-binary=:all:', '--require-hashes', '-r', $requirements) 'installing materialyoucolor/pillow'
    # The commit id in the URL content-addresses the CLI source (git verifies it).
    Invoke-Bounded $python @('-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', '--timeout', '30', '--retries', '1', '--no-deps', '--ignore-requires-python', "git+https://github.com/caelestia-dots/cli@$CliRevision") "installing the caelestia CLI at $CliRevision"

    Copy-Item -LiteralPath $helperSource -Destination $helper -Force
    $shimDir = (& $python -c "import site; print(site.getsitepackages()[0])" 2>$null | Select-Object -First 1)
    if ($shimDir) {
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

    if (-not (Test-Runtime)) {
        throw 'the installed runtime cannot import materialyoucolor/PIL/caelestia'
    }

    [ordered]@{
        available = $true
        revision = $CliRevision
        python = $python
        helper = $helper
        provisionedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $stamp -Encoding UTF8
    Write-Result $true 'provisioned'
} catch {
    $message = $_.Exception.Message
    Write-Warning "Scheme runtime unavailable: $message"
    try { Add-Content -LiteralPath $provisionLog -Value "$((Get-Date).ToString('o')) FAILED: $message" } catch { }
    [ordered]@{
        available = $false
        revision = $CliRevision
        message = $message
        attemptedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $stamp -Encoding UTF8
    Write-Result $false $message
}
