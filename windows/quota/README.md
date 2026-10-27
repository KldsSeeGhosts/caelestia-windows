# CPA quota drawer

Windows port of the CPA quota panel from
[KldsSeeGhosts/caelestia-hypr-dotfiles](https://github.com/KldsSeeGhosts/caelestia-hypr-dotfiles)
(`overlay/quickshell/modules/quota`, `services/Quota.qml`,
`scripts/cpa_usage.py`) at commit
`621dccaf035e1a1b9bf2f808c18c2aa0d26e7db6`. It is the first module tracked by
[issue #56](https://github.com/KldsSeeGhosts/caelestia-windows/issues/56).

## What is staged

| Source here | Staged as |
| --- | --- |
| `modules/quota/{Wrapper,Content,QuotaMeter,QuotaToolTip}.qml` | `modules/quota/` |
| `modules/quota/QuotaLogic.js` | `modules/quota/QuotaLogic.js` |
| `services/Quota.qml` | `services/Quota.qml` |
| `services/QuotaConfig.qml` | `services/QuotaConfig.qml` |
| `scripts/{cpa_usage,cpa_keepalive,read_records}.py` | `scripts/` |
| `assets/provider-icons/*` | `assets/provider-icons/*` |

`QuotaMeter.qml`, `QuotaToolTip.qml` and `QuotaLogic.js` are verbatim from the
overlay. `Wrapper.qml` and `Content.qml` change only the config source
(`GlobalConfig.quota` to `QuotaConfig`), the disabled button guards, and the
"not configured" empty state.

The drawer is wired into the shared drawer graph:

- `components/ScreenState.qml` gains `quota`.
- `modules/drawers/{ContentWindow,Interactions,Regions}.qml` add the close
  paths, hover area, input region and blob deformation.
- `windows/combined-prototype/adapters/modules/drawers/Panels.qml` imports
  `qs.modules.quota`, exposes `quota`, and anchors `Quota.Wrapper` top-right.
- `windows/shell-prototype/adapters/modules/drawers/Panels.qml` keeps an inert
  `quota` slot so the non-combined prototypes still stage the shared files.

There is no bar entry and no default keybind, matching the Linux overlay.

## Windows adaptations

- **Config.** Upstream reads `GlobalConfig.quota` from a patched C++ config
  plugin. This port reads the same schema from an optional `quota.json` in the
  shell config directory, so no plugin rebuild is needed. Defaults match the
  original fallbacks. `QuotaConfig` also resolves the profile paths and Python.
- **Opt-in.** A local `FileView` existence check of `cpa-agents.json` decides
  whether the collector runs at all. QML never accesses the file's contents or
  the admin key; the collector is the only consumer. Missing config means no
  process, no error and a disabled drawer.
- **Processes.** `timeout --kill-after ... python3` becomes
  `[python, "-I", script, ...]`. The QML refresh watchdog and a new ledger
  watchdog replace the GNU `timeout` wrapper. The child receives
  `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `HOME` and `USERPROFILE` so the upstream
  scripts' own path logic keeps working. The profile scheme venv is preferred,
  then `py`.
- **Python.** `cpa_usage.py` and `cpa_keepalive.py` skip the POSIX mode-bit
  check on Windows and skip `os.fchmod` (Unix-only). Nothing else in the
  collector changed; it is otherwise upstream's read-only implementation.
- **Empty states.** No CPA config shows "CPA quota is not configured"; an
  unreachable endpoint shows one saved-data line; no records shows the original
  "No agent usage records found".

## Run the smoke

```powershell
powershell -NoProfile -File windows/scripts/Test-Quota.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot C:\b-quota
```

The harness stages the production graph and runs `QuotaSmoke.qml` offscreen in
three isolated profiles:

1. **configured** - a local synthetic CPA stub (`fixtures/stub_cpa.py`) feeds
   the real `cpa_usage.py`, then the drawer opens with two providers and live
   meters. This exercises the Windows permission and `fchmod` fixes.
2. **offline** - the endpoint refuses connections; one friendly saved-data
   error is allowed and the run must settle without hanging.
3. **unconfigured** - no config; the collector must not run and the drawer must
   stay disabled.

It writes `result.json`, per-mode logs and (configured mode) a screenshot under
a disposable `%TEMP%\caelestia-quota-smoke\<run>` directory. Logs and
screenshots are intentionally not committed.

## Verification limits

- The smoke uses synthetic CPA data, not a real management server. Live CPA
  response shapes, real account inventories, keepalive traffic, provider icon
  appearance at every DPI and the hover feel on the live desktop still need a
  live check.
- The keepalive script keeps upstream's ports and endpoints. It only runs when
  the bolt is pressed, and needs CPA inference reachability and `CPA_API_KEY`.
- The provider icon marks are copied from the custom overlay. They are
  third-party brand marks; verify redistribution terms before publishing.
