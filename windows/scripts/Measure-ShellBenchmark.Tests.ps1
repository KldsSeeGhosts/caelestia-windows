[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'TestRoot must be new.' }
New-Item -ItemType Directory -Path $TestRoot | Out-Null
$test = @'
import copy
import json
import runpy
import sys
from pathlib import Path

module = runpy.run_path(sys.argv[1])
compare = module["compare_groups"]
distribution = module["distribution"]
aggregate = module["aggregate"]
root = Path(sys.argv[2])

def group(values, valid=True, contract=None):
    return {
        "valid": valid, "contract": contract or {"mode": "Offscreen"},
        "metrics": {"latencyMs": distribution(values)},
    }

a = {"A/Panel": group([10, 11, 12, 11, 10])}
for values, verdict in [
    ([10, 11, 12, 11, 10], "no measurable difference"),
    ([11, 12, 13, 12, 11], "no measurable difference"),
    ([20, 21, 22, 21, 20], "slower"),
    ([1, 2, 3, 2, 1], "faster"),
]:
    result = compare(a, {"A/Panel": group(values)})
    assert result["latencyMs"]["verdict"] == verdict, result
for b in [
    {}, {"A/Panel": group([20]*5, valid=False)},
    {"A/Panel": group([20]*5, contract={"mode": "NonVisible"})},
]:
    assert compare(a, b)["Panel"]["verdict"] == "inconclusive"

manifest = {"twoBuilds": True, "runs": []}
for index in range(5):
    for side in ("A", "B"):
        run = root / f"{side}-{index}"
        run.mkdir()
        meta = {
            "schemaVersion": 2, "metric": "Panel", "mode": "Offscreen",
            "machine": "fixture", "os": "fixture", "logicalProcessors": 2,
            "qtVersion": "fixture", "workload": {"cycles": 2},
            "screen": {"ready": True, "dpr": 1, "width": 100, "height": 100},
        }
        completion = {
            "completed": True, "errors": [], "errorCount": 0,
            "work": {"actionsConfirmed": 4, "panelsShown": 2},
        }
        for name, value in [("metadata.json", meta), ("completion.json", completion)]:
            (run / name).write_text(json.dumps(value))
        (run / "samples.csv").write_text("phase,systemCpuPercent\nidle,20\n")
        actions = [
            {"panel": panel, "requestToFrameObservedMs": 10, "shellRequestToFrameMs": 9}
            for panel in ("dashboard", "idle", "launcher", "idle")
        ]
        (run / "actions.jsonl").write_text("\n".join(map(json.dumps, actions)))
        manifest["runs"].append({
            "side": side, "metric": "Panel", "path": str(run), "exitCode": 0,
        })

path = root / "manifest.json"
def summarize(value):
    path.write_text(json.dumps(value))
    return aggregate(path)

result = summarize(manifest)
assert result["groups"]["A/Panel"]["metrics"]["panelRequestToFrameObservedMs"]["runs"] == 5
assert result["groups"]["A/Panel"]["work"]["panelsShown"] == 10
assert result["comparison"]["panelRequestToFrameObservedMs"]["verdict"] == "no measurable difference"

for change in ("missing", "exit", "count", "diagnostic", "workload"):
    broken = copy.deepcopy(manifest)
    run = Path(broken["runs"][0]["path"])
    original = {name: (run / name).read_text() for name in ("metadata.json", "completion.json")}
    if change == "missing":
        broken["runs"].pop(0)
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
    result = summarize(broken)
    assert result["comparison"]["Panel"]["verdict"] == "inconclusive", (change, result)
    for name, content in original.items():
        (run / name).write_text(content)
    if (run / "stdout.log").exists():
        (run / "stdout.log").unlink()

print("Benchmark fixtures passed. Spread, direction, failures, work counts, and contracts checked.")
'@
$test | & py -3 - "$PSScriptRoot\Summarize-ShellRuntime.py" $TestRoot
if ($LASTEXITCODE -ne 0) { throw 'Benchmark fixtures failed.' }
$tokens = $null
$parseErrors = $null
foreach ($script in @('Measure-ShellRuntime.ps1', 'Measure-ShellBenchmark.ps1')) {
    [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\$script", [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors) { throw ($parseErrors -join ' ') }
}
Write-Output 'PowerShell parse checks passed.'
