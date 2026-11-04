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
    result = compare(a, b)
    assert result and all(v["verdict"] == "inconclusive" for v in result.values())

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
assert result["groups"]["A/Panel"]["metrics"]["panelLauncherRequestToFrameObservedMs"]["runs"] == 5
assert result["groups"]["A/Panel"]["metrics"]["panelDashboardRequestToFrameObservedMs"]["median"] == 10
assert result["groups"]["A/Panel"]["work"]["panelsShown"] == 10
assert result["comparison"]["panelRequestToFrameObservedMs"]["verdict"] == "no measurable difference"

for change in ("missing", "exit", "count", "diagnostic", "workload", "order"):
    broken = copy.deepcopy(manifest)
    run = Path(broken["runs"][0]["path"])
    original = {name: (run / name).read_text() for name in ("metadata.json", "completion.json")}
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
    result = summarize(broken)
    assert result["comparison"] and all(
        value["verdict"] == "inconclusive" for value in result["comparison"].values()
    ), (change, result)
    for name, content in original.items():
        (run / name).write_text(content)
    if (run / "stdout.log").exists():
        (run / "stdout.log").unlink()

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
