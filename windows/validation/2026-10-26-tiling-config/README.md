# Tiling config quick smoke, 2026-10-26

Implementation revision: `8e1af8df9a1960353d5102850b408b39c7fb01e6`.
Backend: `6a17ae6019d6606cc2d3e8178623bfe53b227515`, local
`windows/tiling-config` branch in the backend fork, not pushed.
Windows 11 `10.0.26300`, Qt 6.11.2, clang-cl 20.1.8, VS 2022, Ninja.
Output/build root: this checkout's `windows/.local/build`.

The run records originally name integration `4697ffa8` plus dirty edits.
All 221 final combined staged-source hashes were compared with the committed
implementation and match. Sources and per-run source manifests are not copied
here. The implementation revision reproduces the staged QML.

| Check | Result | Evidence |
| --- | --- | --- |
| Separate native backend and portable plugin build | Passed | build/configure logs, exact local build helper scripts |
| `-Combined -Smoke` default | Passed, tiling off | `combined-default.*.log` |
| Combined profile-only Observe, gaps 10/10 | Passed, included=1/excluded=2, enabled=false at startup/end | `combined-observe.*.log`, screenshot |
| Native config reload smoke | Passed: 10/10 to 12/14, changed rules, then off/unloaded | `profile-reload.*.log` |
| QML policy fixture | 180 assertions passed | `qml-fixture.*.log` |
| Native policy fixture | 28 tests passed | `scoped-rules-test.txt` |
| File-only KSG importer | Passed | `importer-result.json` |
| Prerequisite report | Pins match; ordinary shell PATH lacks build tools | `environment.json`; build ran inside VS environment |

Commands used from the repository root, with `$qt` set to
`C:\Users\Ermin\AppData\Local\caelestia-dev\Qt\6.11.2\msvc2022_64`:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 -QtPrefix $qt -BuildRoot windows/.local/build -Combined -Smoke
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 -QtPrefix $qt -BuildRoot windows/.local/build -Combined -TilingConfigFile windows/.local/observe-shell.json -Smoke
powershell -NoProfile -File windows/scripts/Test-TilingConfig.ps1 -QtPrefix $qt -BuildRoot windows/.local/build
powershell -NoProfile -File windows/scripts/Test-TilingService.ps1 -QtPrefix $qt
powershell -NoProfile -File windows/scripts/Test-KsgSettingsImport.ps1
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -QtPrefix $qt -QuickshellExecutable windows/.local/build/quickshell/qs.exe -Json
```

The temporary Observe input contained:

```json
{"windows":{"tiling":{"enabled":true,"mode":"observe","gapsIn":10,"gapsOut":10,"include":["exe:caelestia-config-fixture.exe"],"float":["title:*Dialog*"],"monitors":{"CAELESTIA_FIXTURE_DISABLED_SCREEN":false}}}}
```

The native test build initially hit the known LLVM linker manifest problem;
the recorded passing test build uses MSVC linking and Windows SDK `mt.exe`.
An initial default combined run reached its PASS marker but the harness
could not finish its result because the manual build lacked `logs/build.json`.
The build record was added and subsequent completed runs are archived here.

The existing `ksg-shell.exe` PID 24108 remained running. Native tests used
only off/Observe and never requested Interactive. Mutex refusal, typed
class/exe admission and monitor transfer were checked with injected/fake facts;
native Interactive placement and real mutex contention were not tested.
Observe preserves the backend's existing parked-window rescue behavior.

The backend commit is available locally through `windows/deps/quickshell`
and the backend worktree `windows/.local/tiling-backend`; integration must
transfer/publish it with the updated pin. No push or PR was performed.
