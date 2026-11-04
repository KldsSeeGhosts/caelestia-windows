[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'TestRoot must be new.' }
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$TestRoot = (Resolve-Path -LiteralPath $TestRoot).Path
$test = @'
import copy
import json
import re
import runpy
import subprocess
import sys
from pathlib import Path

script = sys.argv[1]
module = runpy.run_path(script)
compare = module["compare_groups"]
distribution = module["distribution"]
aggregate = module["aggregate"]
overall = module["overall_verdict"]
exit_codes = module["EXIT_CODES"]
root = Path(sys.argv[2])
user = sys.argv[3]
user_pattern = re.compile(r"(?<![A-Za-z0-9._~-])" + re.escape(user) + r"(?![A-Za-z0-9._~-])", re.I)

def group(values, valid=True, contract=None, name="latencyMs"):
    return {
        "valid": valid, "contract": contract or {"mode": "Offscreen"},
        "metrics": {name: distribution(values)}, "trials": [],
    }

# Median delta against the larger run-to-run range of the two sides.
a = {"A/Panel": group([10, 11, 12, 11, 10])}
for values, verdict in [
    ([10, 11, 12, 11, 10], "same"),
    ([11, 12, 13, 12, 11], "same"),
    ([20, 21, 22, 21, 20], "regressed"),
    ([1, 2, 3, 2, 1], "improved"),
]:
    entry = compare(a, {"A/Panel": group(values)})["latencyMs"]
    assert entry["verdict"] == verdict, entry
    assert entry["baselineMedian"] == 11 and entry["noiseFloor"] == 2, entry
    assert entry["delta"] == entry["candidateMedian"] - 11, entry

# Missing, failed, incompatible and one-sided metrics are never a pass.
for b in [
    {}, {"A/Panel": group([20]*5, valid=False)},
    {"A/Panel": group([20]*5, contract={"mode": "NonVisible"})},
    {"A/Panel": group([11]*5, name="otherMs")},
]:
    result = compare(a, b)
    assert result and all(v["verdict"] == "inconclusive" for v in result.values()), result
    assert overall(result) in ("inconclusive", "mismatch"), result
mismatch = compare(a, {"A/Panel": group([10]*5, contract={"mode": "NonVisible"})})
assert overall(mismatch) == "mismatch" and mismatch["latencyMs"]["contractMismatch"] == ["mode"], mismatch
assert overall({}) == "inconclusive"
# Comparing against a baseline covers the categories measured now.
wide = {"A/Panel": group([10]*5), "A/Idle": group([1]*5, name="idleMs")}
assert set(compare(wide, {"A/Panel": group([10]*5)}, categories={"Panel"})) == {"latencyMs"}
assert compare({"A/Panel": group([10]*5)}, {"A/Idle": group([1]*5)}, categories={"Idle"})["latencyMs"]["verdict"] == "inconclusive"

# Overall verdict precedence and exit codes.
def entries(*verdicts, mismatched=False):
    return {
        str(i): {"verdict": v, "gating": True, "contractMismatch": ["mode"] if mismatched and v == "inconclusive" else []}
        for i, v in enumerate(verdicts)
    }
for verdicts, expected, code in [
    (("same", "same"), "same", 0),
    (("same", "improved"), "improved", 0),
    (("improved", "regressed"), "regressed", 2),
    (("same", "inconclusive"), "inconclusive", 3),
    (("regressed", "inconclusive"), "regressed", 2),
]:
    assert overall(entries(*verdicts)) == expected and exit_codes[expected] == code, verdicts
assert overall(entries("regressed", "inconclusive", mismatched=True)) == "mismatch" and exit_codes["mismatch"] == 4
advisory = entries("same", "regressed")
advisory["1"]["gating"] = False
assert overall(advisory) == "same"

def write_trial(run, ms=10):
    run.mkdir(parents=True)
    # Private strings in raw metadata and logs must not reach shareable records.
    meta = {
        "schemaVersion": 2, "metric": "Panel", "mode": "Offscreen",
        "machine": "fixture", "os": "fixture", "logicalProcessors": 2,
        "qtVersion": "fixture", "workload": {"cycles": 2},
        "screen": {"ready": True, "dpr": 1, "width": 100, "height": 100},
        "shellRevision": "fixture-revision", "build": {"qtPrefix": "C:\\Users\\" + user + "\\Qt"},
    }
    completion = {
        "completed": True, "errors": [], "errorCount": 0,
        "work": {"actionsConfirmed": 4, "panelsShown": 2},
    }
    for name, value in [("metadata.json", meta), ("completion.json", completion)]:
        (run / name).write_text(json.dumps(value))
    (run / "samples.csv").write_text("phase,systemCpuPercent\nidle,20\n")
    (run / "stdout.log").write_text("INFO quickshell.startup: loaded C:\\Users\\" + user + "\\shell.qml\n")
    actions = [
        {"panel": panel, "requestToFrameObservedMs": ms, "shellRequestToFrameMs": ms - 1}
        for panel in ("dashboard", "idle", "launcher", "idle")
    ]
    (run / "actions.jsonl").write_text("\n".join(map(json.dumps, actions)))

def make_manifest(name, b_ms=10, sides=("A", "B")):
    manifest = {"twoBuilds": len(sides) == 2, "runs": []}
    for index in range(5):
        for side in sides:
            run = root / name / f"{side}-{index}"
            write_trial(run, b_ms if side == "B" else 10)
            manifest["runs"].append({"side": side, "metric": "Panel", "path": str(run), "exitCode": 0})
    return manifest

manifest = make_manifest(".")
path = root / "manifest.json"
def summarize(value):
    path.write_text(json.dumps(value))
    return aggregate(path)

result = summarize(manifest)
assert result["groups"]["A/Panel"]["metrics"]["panelRequestToFrameObservedMs"]["runs"] == 5
assert result["groups"]["A/Panel"]["metrics"]["panelLauncherRequestToFrameObservedMs"]["runs"] == 5
assert result["groups"]["A/Panel"]["metrics"]["panelDashboardRequestToFrameObservedMs"]["median"] == 10
assert result["groups"]["A/Panel"]["work"]["panelsShown"] == 10
assert result["comparison"]["panelRequestToFrameObservedMs"]["verdict"] == "same"

for change in ("missing", "exit", "count", "diagnostic", "workload", "order", "display"):
    broken = copy.deepcopy(manifest)
    run = Path(broken["runs"][0]["path"])
    original = {name: (run / name).read_text() for name in ("metadata.json", "completion.json", "stdout.log")}
    if change == "missing":
        broken["runs"] = broken["runs"][:-2]
    elif change == "exit":
        broken["runs"][0]["exitCode"] = 1
    elif change == "count":
        completion = json.loads((run / "completion.json").read_text())
        completion["work"]["panelsShown"] = 0
        (run / "completion.json").write_text(json.dumps(completion))
    elif change == "diagnostic":
        (run / "stdout.log").write_text("ERROR fixture\n")
    elif change == "workload":
        meta = json.loads((run / "metadata.json").read_text())
        meta["workload"]["cycles"] = 9
        (run / "metadata.json").write_text(json.dumps(meta))
    elif change == "order":
        broken["runs"].sort(key=lambda value: value["side"])
    elif change == "display":
        broken["runs"][0]["displayChanged"] = True
    result = summarize(broken)
    assert result["comparison"] and all(
        value["verdict"] == "inconclusive" for value in result["comparison"].values()
    ), (change, result)
    for name, content in original.items():
        (run / name).write_text(content)

# The command line writes verdict.json and exits with its code.
def cli(name, value, compare_with=None):
    out = root / ("cli-" + name)
    out.mkdir()
    (out / "manifest.json").write_text(json.dumps(value))
    command = [sys.executable, script, str(out / "manifest.json"), "--manifest",
               "--output", str(out / "benchmark.json"), "--verdict", str(out / "verdict.json"),
               "--baselines", str(out)]
    if compare_with:
        command += ["--compare", str(compare_with)]
    code = subprocess.run(command).returncode
    verdict = json.loads((out / "verdict.json").read_text())
    assert verdict["schemaVersion"] == 1 and verdict["exitCode"] == code, (name, verdict)
    return code, verdict, out

code, verdict, same = cli("same", manifest)
assert code == 0 and verdict["overall"] == "same", verdict
assert [c["baseline"] + "/" + c["candidate"] for c in verdict["comparisons"]] == ["A/B"], verdict
# Shareable records carry no account name; the raw evidence did contain it.
assert user_pattern.search((same / "benchmark.json").read_text().replace("\\\\", "\\"))
for name in ("verdict.json", "baseline-A.json", "baseline-B.json"):
    assert not user_pattern.search((same / name).read_text().replace("\\\\", "\\")), name
saved = same / "baseline-A.json"
assert json.loads(saved.read_text())["groups"]["A/Panel"]["valid"]

code, verdict, _ = cli("baseline", manifest, saved)
assert code == 0 and [c["overall"] for c in verdict["comparisons"]] == ["same", "same"], verdict
assert verdict["comparisons"][1]["baseline"] == "baseline:baseline-A", verdict

code, verdict, _ = cli("planted", make_manifest("planted", b_ms=20))
assert code == 2 and verdict["overall"] == "regressed", verdict
assert verdict["comparisons"][0]["metrics"]["panelRequestToFrameObservedMs"]["delta"] == 10, verdict

code, verdict, _ = cli("measured", make_manifest("measured", sides=("A",)))
assert code == 0 and verdict["overall"] == "measured" and not verdict["comparisons"], verdict

broken = make_manifest("broken")
completion = Path(broken["runs"][1]["path"]) / "completion.json"
completion.write_text(completion.read_text().replace('"panelsShown": 2', '"panelsShown": 0'))
code, verdict, _ = cli("inconclusive", broken)
assert code == 3 and verdict["overall"] == "inconclusive", verdict
code, verdict, _ = cli("measured-broken", {"twoBuilds": False, "runs": [r for r in broken["runs"] if r["side"] == "B"]})
assert code == 3 and verdict["overall"] == "inconclusive", verdict

other = json.loads(saved.read_text())
other["groups"]["A/Panel"]["contract"]["qtVersion"] = "other"
(root / "other.json").write_text(json.dumps(other))
code, verdict, _ = cli("mismatch", manifest, root / "other.json")
assert code == 4 and verdict["overall"] == "mismatch", verdict
assert verdict["comparisons"][1]["metrics"]["panelRequestToFrameObservedMs"]["contractMismatch"] == ["qtVersion"], verdict

idle = root / "idle-endpoints"
idle.mkdir()
meta = json.loads((root / "A-0" / "metadata.json").read_text())
meta["metric"] = "Idle"
meta["workload"] = {"idleSeconds": 2}
(idle / "metadata.json").write_text(json.dumps(meta))
(idle / "completion.json").write_text(json.dumps({
    "completed": True, "errors": [],
    "work": {"actionsConfirmed": 0, "panelsShown": 0, "idleIntervals": 1},
}))
(idle / "actions.jsonl").write_text("")
(idle / "samples.csv").write_text(
    "phase,elapsedSeconds,cpuSeconds,systemCpuPercent\n"
    "idle,0,1,20\nidle,2,1.25,20\n"
)
trial = module["summarize_trial"](idle)
assert trial["errorCount"] == 0, trial
assert trial["metrics"]["idleCpuCorePercent"] == 12.5
meta["workload"]["idleSeconds"] = 3
(idle / "metadata.json").write_text(json.dumps(meta))
assert module["summarize_trial"](idle)["errorCount"] > 0

print("Benchmark fixtures passed. Verdicts, exit codes, failures, work counts, contracts, baselines and privacy checked.")
'@
$test | & py -3 - "$PSScriptRoot\Summarize-ShellRuntime.py" $TestRoot $env:USERNAME
if ($LASTEXITCODE -ne 0) { throw 'Benchmark fixtures failed.' }
$tokens = $null
$parseErrors = $null
foreach ($script in @('Measure-ShellRuntime.ps1', 'Measure-ShellBenchmark.ps1', 'Caelestia-Privacy.ps1', 'Test-Candidate.ps1')) {
    [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\$script", [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors) { throw ($parseErrors -join ' ') }
}
Write-Output 'PowerShell parse checks passed.'

# metadata.json, verdict.json and baselines pass the same privacy check the runner applies.
. "$PSScriptRoot\Caelestia-Privacy.ps1"
Initialize-CaelestiaPrivacy @(@{ from = $TestRoot; to = '<runRoot>' })
$profiles = Split-Path -Parent $env:USERPROFILE
$private = [ordered]@{
    environment = [ordered]@{ QML_IMPORT_PATH = "$env:USERPROFILE\Qt\qml;$TestRoot\stage" }
    build = [pscustomobject]@{ qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt"; other = "$profiles\SomeoneElse\x" }
    note = "owner $env:USERNAME"
}
$private | ConvertTo-Json -Depth 8 | Set-Content "$TestRoot\private.json"
ConvertTo-SafeManifestValue $private | ConvertTo-Json -Depth 8 | Set-Content "$TestRoot\redacted.json"
if ((Get-ManifestPrivacyReport "$TestRoot\private.json").userHits -lt 1) { throw 'The privacy check missed the account name.' }
if ((Get-ManifestPrivacyReport "$TestRoot\redacted.json").total -ne 0) { throw 'Redacted metadata still names the account or a home path.' }
foreach ($record in @('cli-same\verdict.json', 'cli-same\baseline-A.json', 'cli-planted\verdict.json', 'cli-mismatch\verdict.json')) {
    if ((Get-ManifestPrivacyReport "$TestRoot\$record").total -ne 0) { throw "Private data in $record." }
}
Write-Output 'Privacy checks passed.'

$baseline = Join-Path $TestRoot 'publication.json'
[IO.File]::Copy("$TestRoot\A-0\metadata.json", $baseline, $false)
$baselineHash = (Get-FileHash $baseline).Hash
$refused = $false
try { [IO.File]::Copy("$TestRoot\B-0\completion.json", $baseline, $false) } catch [IO.IOException] { $refused = $true }
if (-not $refused -or (Get-FileHash $baseline).Hash -ne $baselineHash) { throw 'Exclusive baseline publication failed.' }
$hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($script in @('Measure-ShellRuntime.ps1', 'Measure-ShellBenchmark.ps1')) {
    $run = Join-Path $TestRoot "$script-Live-must-not-exist"
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $hostPath
    $info.WorkingDirectory = $TestRoot
    $info.Arguments = '-NoProfile -File "' + "$PSScriptRoot\$script" +
        '" -QtPrefix "' + $PSScriptRoot + '" -BuildRoot "' + $PSScriptRoot +
        '" -SourceRoot "' + "$PSScriptRoot\..\.." + '" -RunRoot "' + $run + '" -Mode Live'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    $child = [Diagnostics.Process]::Start($info)
    try {
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'Live refusal timed out.' }
        if ($child.ExitCode -eq 0 -or (Test-Path -LiteralPath $run) -or
            $stderr.GetAwaiter().GetResult() -notlike '*Live trials require -LiveDesktop*') {
            throw "Live startup was not refused: $script"
        }
    } finally { $child.Dispose() }
}
Write-Output 'Live launch refusal and exclusive baseline publication passed.'

# Failed trials end in an inconclusive verdict, not an aborted run. A missing
# build root makes every worker fail before it starts a shell.
$run = Join-Path $TestRoot 'failed-workers'
$ErrorActionPreference = 'Continue'
& $hostPath -NoProfile -File "$PSScriptRoot\Measure-ShellBenchmark.ps1" -QtPrefix $PSScriptRoot `
    -BuildRoot (Join-Path $TestRoot 'missing-build') -SourceRoot "$PSScriptRoot\..\.." `
    -RunRoot $run -Metric Reload *> (Join-Path $TestRoot 'failed-workers.log')
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$verdict = if (Test-Path -LiteralPath "$run\verdict.json") { Get-Content -LiteralPath "$run\verdict.json" -Raw | ConvertFrom-Json }
if ($code -ne 3 -or $verdict.overall -ne 'inconclusive' -or $verdict.groups.'A/Reload'.trials -ne 0) {
    throw "Failed trials gave exit $code and verdict '$($verdict.overall)' instead of exit 3 and inconclusive."
}
# The runner held, and released, a system and display power request, and recorded the topology.
if (-not ($verdict.powerRequest.held -and $verdict.powerRequest.system -and $verdict.powerRequest.display) -or -not $verdict.displays) {
    throw 'The verdict does not record a held power request and the display topology.'
}
Write-Output 'Failed-trial verdict and power request passed.'
