"""Offline regression for Python's indirect launch of Windows PowerShell.

Run with Python 3.12: ToolchainModules.test.py --output-root <fixture/log directory>.
No downloads, tool installations, or caller environment changes are performed.
"""
import argparse
import base64
import hashlib
import os
from pathlib import Path
import subprocess
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
    archive = root / "fixture.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("fixture.txt", "verified fixture")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
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
'PASS {name}: verified hash, extraction, invalid hash, malformed hash, missing file, unchanged module path'
"""
        result = run(name + "-restored-pass", body, inherited)
        if result.returncode != 0 or f"PASS {name}:" not in result.stdout:
            raise AssertionError(result.stdout)
        print(next(line for line in result.stdout.splitlines() if line.startswith(f"PASS {name}:")))
    print("PASS Python -> PowerShell 5.1 module-boundary regression")


if __name__ == "__main__":
    main()
