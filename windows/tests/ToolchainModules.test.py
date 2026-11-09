"""Offline regression for Python's indirect launch of Windows PowerShell.

Run with Python 3.12: ToolchainModules.test.py --output-root <fixture/log directory>.
No downloads, tool installations, or caller environment changes are performed.
"""
import argparse
import base64
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import zipfile


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    root = args.output_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    helper = Path(__file__).resolve().parents[1] / "scripts/Caelestia-Toolchain.ps1"
    prepare = helper.with_name("Prepare-Toolchain.ps1")
    archive = root / "fixture.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("fixture.txt", "verified fixture")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    llvm_archive = root / "llvm-fixture.tar"
    with tarfile.open(llvm_archive, "w") as bundle:
        for name in ("fixture-llvm", "fixture-llvm/bin", "fixture-llvm/lib",
                     "fixture-llvm/lib/clang", "fixture-llvm/lib/clang/20",
                     "fixture-llvm/lib/clang/20/include", "fixture-llvm/include"):
            entry = tarfile.TarInfo(name)
            entry.type = tarfile.DIRTYPE
            bundle.addfile(entry)
        for name in ("bin/clang-cl.exe", "bin/lld-link.exe", "bin/llvm-rc.exe", "bin/clang-scan-deps.exe",
                     "bin/llvm-ar.exe", "bin/llvm-lib.exe", "bin/llvm-ranlib.exe", "bin/llvm-nm.exe",
                     "bin/llvm-mt.exe", "bin/unused.exe", "bin/unused.dll", "lib/clang/20/include/stddef.h",
                     "lib/unused-sdk.lib", "include/unused-api.h"):
            payload = b"synthetic archive member, never executed"
            entry = tarfile.TarInfo("fixture-llvm/" + name)
            entry.size = len(payload)
            bundle.addfile(entry, io.BytesIO(payload))
    llvm_digest = hashlib.sha256(llvm_archive.read_bytes()).hexdigest()
    # An incompatible caller module must not shadow the current engine's inbox
    # modules. It also prevents accidental success on machines with pwsh absent.
    modules = root / "PowerShell-7-Modules"
    for name in ("Microsoft.PowerShell.Utility", "Microsoft.PowerShell.Archive"):
        module = modules / name
        module.mkdir(parents=True, exist_ok=True)
        (module / (name + ".psd1")).write_text(
            "@{ ModuleVersion = '1.0'; PowerShellVersion = '99.0'; "
            f"RootModule = '{name}.psm1'; "
            "FunctionsToExport = @('Get-FileHash', 'Expand-Archive') }\n",
            encoding="utf-8",
        )
        (module / (name + ".psm1")).write_text(
            "throw 'An incompatible caller module was imported.'\n", encoding="utf-8"
        )
    preamble = (
        "$ErrorActionPreference = 'Stop'\n"
        "$ProgressPreference = 'SilentlyContinue'\n"
        f". {quote(helper)}\n"
        "$originalModulePath = $env:PSModulePath\n"
    )

    def run(name, body, inherited):
        env = os.environ.copy()
        # Keep process-local discovery output inside the fixture. os.environ
        # normalizes Windows keys to uppercase; avoid duplicate differently
        # cased PSModulePath entries in CreateProcess's environment block.
        env["PSMODULEANALYSISCACHEPATH"] = str(root / (name + "-module-cache"))
        env["LOCALAPPDATA"] = str(root / (name + "-localappdata"))
        if inherited:
            env["PSMODULEPATH"] = str(modules)
        else:
            # Let Windows PowerShell construct its ordinary module path.
            env.pop("PSMODULEPATH", None)
        encoded = base64.b64encode((preamble + body).encode("utf-16-le")).decode("ascii")
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        (root / (name + ".log")).write_text(result.stdout, encoding="utf-8")
        return result

    # Record the uninitialized baseline honestly: Windows servicing versions
    # differ in whether command discovery falls back to PSHOME. A missing inbox
    # search path alone does not reproduce the hosted failure on every host.
    old = run(
        "uninitialized-inherited-baseline",
        f"$env:PSModulePath\nAssert-CaelestiaDownload {quote(archive)} '{digest}'\n",
        True,
    )
    print(f"Uninitialized inherited-path baseline exit={old.returncode} (see log)")

    # Unlike the host-dependent discovery baseline above, this control
    # deterministically removes script-module functions in this process.
    no_autoload = """
Import-Module -Name (Join-Path $PSHOME 'Modules\\Microsoft.PowerShell.Management\\Microsoft.PowerShell.Management.psd1') -Global -ErrorAction Stop
Remove-Module Microsoft.PowerShell.Utility -Force -ErrorAction SilentlyContinue
$PSModuleAutoLoadingPreference = 'None'
"""
    missing = run("child-without-inbox-module", no_autoload + f"""
Get-FileHash -LiteralPath {quote(archive)} -Algorithm SHA256
""", True)
    if missing.returncode == 0 or "Get-FileHash" not in missing.stdout:
        raise AssertionError("Missing inbox-module negative control did not fail")

    # Evaluate each entry point's actual startup statements through its explicit
    # initializer, not a retyped bootstrap. Do not execute build/install/native
    # fixture bodies. Every run is a fresh Python -> PowerShell process.
    for entry in (
        "Caelestia-QmlFixture.ps1", "Test-StagedServiceModels.ps1",
        "Stage-ShellPrototype.ps1", "Build-Prototype.ps1",
        "New-CaelestiaRelease.ps1", "Test-Smoke.ps1",
        "Test-UpdatesStatus.ps1",
        "../ci/New-NexusCandidate.ps1", "../ci/Test-NexusCandidatePayload.ps1",
    ):
        script = (helper.parent / entry).resolve()
        body = no_autoload + f"""
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile({quote(script)}, [ref]$tokens, [ref]$errors)
if ($errors.Count) {{ throw 'Entry point does not parse.' }}
$parts = [Collections.Generic.List[string]]::new()
$found = $false
foreach ($statement in $ast.EndBlock.Statements) {{
    $parts.Add($statement.Extent.Text)
    if ($statement.Extent.Text -ceq 'Initialize-CaelestiaToolchainModules') {{
        $found = $true
        break
    }}
}}
if (-not $found) {{ throw 'Entry point has no explicit module initializer.' }}
$bootstrapRoot = {quote(script.parent)}
$prefix = ($parts -join "`n").Replace('$PSScriptRoot', "'" + $bootstrapRoot.Replace("'", "''") + "'")
. ([scriptblock]::Create($prefix))
Assert-CaelestiaDownload {quote(archive)} '{digest}'
if ((Get-Module Microsoft.PowerShell.Utility).Path -notlike "$PSHOME\\Modules\\Microsoft.PowerShell.Utility\\*") {{
    throw 'Entry point did not load its own engine module.'
}}
if ($env:PSModulePath -cne $originalModulePath) {{ throw 'Entry point changed PSModulePath.' }}
'PASS actual child bootstrap: {entry}'
"""
        checked = run("child-" + script.stem, body, True)
        if checked.returncode != 0 or f"PASS actual child bootstrap: {entry}" not in checked.stdout:
            raise AssertionError(checked.stdout)
        print(f"PASS actual child bootstrap: {entry}")

    # This fixture runs before the QML helper is imported by Test-UpdatesPage.
    # Execute its full installed-status contract under the inherited module
    # path as well as checking startup. It owns disposable synthetic records
    # only, makes no network request and does not operate the installed shell.
    checked = run("child-updates-status-contract", no_autoload + f"""
& {quote(helper.with_name('Test-UpdatesStatus.ps1'))}
""", True)
    if checked.returncode != 0 or "PASS updates Status contract: 27 assertions" not in checked.stdout:
        raise AssertionError(checked.stdout)
    print("PASS inherited-path installed-status contract: 27 assertions")

    for inherited in (False, True):
        name = "inherited" if inherited else "normal"
        destination = root / (name + "-extracted")
        body = f"""
Initialize-CaelestiaToolchainModules
foreach ($module in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Archive')) {{
    if ((Get-Module $module).Path -notlike "$PSHOME\\Modules\\$module\\*") {{
        throw "Did not load the running engine's inbox module: $module"
    }}
}}
$null = Get-CaelestiaToolchain
Assert-CaelestiaDownload {quote(archive)} '{digest}'
Expand-Archive -LiteralPath {quote(archive)} -DestinationPath {quote(destination)} -Force
if ([IO.File]::ReadAllText({quote(destination / 'fixture.txt')}) -cne 'verified fixture') {{
    throw 'Archive extraction did not preserve the fixture.'
}}
foreach ($case in @(
    @({quote(archive)}, ('0' * 64)),
    @({quote(archive)}, 'invalid'),
    @({quote(root / 'missing.zip')}, '{digest}'))) {{
    $rejected = $false
    try {{ Assert-CaelestiaDownload $case[0] $case[1] }}
    catch {{
        if ($_.Exception.Message -notmatch 'checksum mismatch or missing archive') {{ throw }}
        $rejected = $true
    }}
    if (-not $rejected) {{ throw 'Integrity check accepted an invalid archive.' }}
}}
if ($env:PSModulePath -cne $originalModulePath) {{ throw 'Initializer changed PSModulePath.' }}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile({quote(prepare)}, [ref]$tokens, [ref]$errors)
if ($errors.Count) {{ throw 'Prepare source does not parse.' }}
$definition = $ast.Find({{
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-VerifiedToolchainArchive'
}}, $true)
if ($null -eq $definition) {{ throw 'Missing production archive function.' }}
. ([scriptblock]::Create($definition.Extent.Text))
$downloads = {quote(root / (name + "-downloads"))}
$null = [IO.Directory]::CreateDirectory($downloads)
$script:fixtureArchive = {quote(archive)}
$script:curlCalls = 0
$script:curlFails = $false
function curl.exe {{
    $script:curlCalls++
    $script:curlArguments = @($args)
    if ($script:curlFails) {{ $global:LASTEXITCODE = 28; return }}
    $outputIndex = [Array]::IndexOf($script:curlArguments, '-o') + 1
    if ($outputIndex -eq 0) {{ throw 'Archive output argument missing.' }}
    [IO.File]::WriteAllBytes($script:curlArguments[$outputIndex], [IO.File]::ReadAllBytes($script:fixtureArchive))
    $global:LASTEXITCODE = 0
}}
$download = [pscustomobject]@{{ file = 'synthetic.zip'; url = 'https://fixture.invalid/never-contacted'; sha256 = '{digest}' }}
$resolved = Get-VerifiedToolchainArchive $download
foreach ($bound in @(@('--connect-timeout', '30'), @('--max-time', '600'), @('--retry', '2'))) {{
    $index = [Array]::IndexOf($script:curlArguments, $bound[0])
    if ($index -lt 0 -or $script:curlArguments[$index + 1] -cne $bound[1]) {{
        throw "Production download is not bounded: $($bound[0])"
    }}
}}
if ($resolved -cne (Join-Path $downloads $download.file)) {{ throw 'Archive function returned extra output.' }}
$null = Get-VerifiedToolchainArchive $download
if ($script:curlCalls -ne 1) {{ throw 'Verified cached archive was downloaded again.' }}
$bad = [pscustomobject]@{{ file = 'bad.zip'; url = $download.url; sha256 = ('0' * 64) }}
$rejected = $false
try {{ $null = Get-VerifiedToolchainArchive $bad }}
catch {{ if ($_.Exception.Message -notmatch 'checksum mismatch') {{ throw }}; $rejected = $true }}
if (-not $rejected) {{ throw 'Downloaded bytes bypassed the pinned hash.' }}
$script:curlFails = $true
$bad.file = 'timeout.zip'
$rejected = $false
try {{ $null = Get-VerifiedToolchainArchive $bad }}
catch {{ if ($_.Exception.Message -notmatch 'Download failed') {{ throw }}; $rejected = $true }}
if (-not $rejected) {{ throw 'Download timeout was accepted.' }}
$extract = $ast.Find({{
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '\\$llvmExtractor\\s+--archive'
}}, $true)
if ($null -eq $extract) {{ throw 'Missing production LLVM extraction command.' }}
$llvm = {quote(llvm_archive)}
$ToolRoot = {quote(root / (name + "-llvm"))}
$spec = [pscustomobject]@{{ llvmDirectory = 'fixture-llvm'; clangVersion = '20.1.8';
    downloads = [pscustomobject]@{{ llvm = [pscustomobject]@{{ sha256 = '{llvm_digest}' }} }} }}
$venvPython = {quote(sys.executable)}
$llvmExtractor = {quote(prepare.parent.parent / 'toolchain' / 'extract_llvm.py')}
$llvmProfile = 'full'
$null = [IO.Directory]::CreateDirectory($ToolRoot)
& ([scriptblock]::Create($extract.Extent.Text))
if ($LASTEXITCODE -ne 0) {{ throw 'Production LLVM member extraction failed.' }}
foreach ($file in @('bin/clang-cl.exe', 'lib/clang/20/include/stddef.h')) {{
    if ([IO.File]::ReadAllText("$ToolRoot/fixture-llvm/$file") -cne 'synthetic archive member, never executed') {{
        throw 'Compiler binary or built-in resource bytes were not preserved.'
    }}
}}
if ((Test-Path "$ToolRoot/fixture-llvm/lib/unused-sdk.lib") -or
    (Test-Path "$ToolRoot/fixture-llvm/include/unused-api.h")) {{
    throw 'Production extraction materialized the unused LLVM development SDK.'
}}
if (-not (Test-Path "$ToolRoot/fixture-llvm/.caelestia-extraction.json")) {{
    throw 'Complete extraction marker missing.'
}}
$ToolRoot = {quote(root / (name + "-llvm-native"))}
$llvmProfile = 'windows-native-v1'
$null = [IO.Directory]::CreateDirectory($ToolRoot)
& ([scriptblock]::Create($extract.Extent.Text))
if ($LASTEXITCODE -ne 0) {{ throw 'Production native LLVM profile extraction failed.' }}
if ((Test-Path "$ToolRoot/fixture-llvm/bin/unused.exe") -or
    (Test-Path "$ToolRoot/fixture-llvm/bin/unused.dll")) {{ throw 'Native profile retained unselected bin payload.' }}
$marker = Get-Content "$ToolRoot/fixture-llvm/.caelestia-extraction.json" -Raw | ConvertFrom-Json
if ($marker.schemaVersion -ne 2 -or $marker.profile -cne $llvmProfile) {{ throw 'Native marker did not bind profile.' }}
$readiness = $ast.Find({{
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.Extent.Text -match '\\$llvmExtractor\\s+--verify-tree'
}}, $true)
if ($null -eq $readiness) {{ throw 'Missing production LLVM profile readiness command.' }}
& ([scriptblock]::Create($readiness.Extent.Text))
if ($LASTEXITCODE -ne 0) {{ throw 'Complete native cache was not accepted.' }}
[IO.File]::Delete("$ToolRoot/fixture-llvm/bin/clang-scan-deps.exe")
& ([scriptblock]::Create($readiness.Extent.Text))
if ($LASTEXITCODE -ne 2) {{ throw 'Incomplete native cache was accepted.' }}
'PASS {name}: actual LLVM extraction command preserves binaries/resources and excludes unused SDK'
'PASS {name}: production archive download bounds, cache, checksum and timeout refusal (fake curl; no network)'
'PASS {name}: verified hash, extraction, invalid hash, malformed hash, missing file, unchanged module path'
"""
        result = run(name + "-restored-pass", body, inherited)
        if result.returncode != 0 or f"PASS {name}:" not in result.stdout:
            raise AssertionError(result.stdout)
        print(next(line for line in result.stdout.splitlines() if line.startswith(f"PASS {name}:")))
    print("PASS Python -> PowerShell 5.1 module-boundary regression")


if __name__ == "__main__":
    main()
