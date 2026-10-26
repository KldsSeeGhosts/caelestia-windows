# KSG settings importer smoke, 2026-10-26

File-only validation on Windows 11, Windows PowerShell 5.1.26100.9711.
`result.json` records the source revisions, importer SHA-256, safe real-settings
summary, fixture results and prerequisite limitations. The containing commit
provides the importer source; no staged source/config copies are archived.

Commands from the repository root:

```powershell
powershell -NoProfile -File windows/scripts/Test-KsgSettingsImport.ps1
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1 -Summary
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

Both importer invocations above use stdout only. The real-settings
JSON was parsed in memory, not saved in the archive. Nine source preferences
mapped; all were enabled. Saved tiling was enabled with gap/padding 10/10 DIPs,
reported but not applied. No warnings; no existing production config.

Compared hashes of all four files in the existing KSG roaming profile before
and after the real dry run and fixture smoke: unchanged. Compared the existing
KSG process ID before and after: unchanged (one process). No KSG process was
started, stopped or reconfigured. The fixture writes only its own temporary
files and verifies dry-run, merge, refusal and backup behavior.

No private paths, unknown source values, pins, source config, credentials or
tokens are included. `smoke.log` contains only the fixture's safe result.
There is no rendered UI or screenshot for this command-line converter.
The environment report is a prerequisite report only; native tools were not
available on the ordinary PATH. No native build, shell launch or live
switch-over was attempted.
