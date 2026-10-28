# CPA quota drawer

Windows port of the CPA quota panel from
[KldsSeeGhosts/caelestia-hypr-dotfiles](https://github.com/KldsSeeGhosts/caelestia-hypr-dotfiles)
(`overlay/quickshell/modules/quota`, `services/Quota.qml`) at commit
`621dccaf035e1a1b9bf2f808c18c2aa0d26e7db6`. It is the first module tracked by
[issue #56](https://github.com/KldsSeeGhosts/caelestia-windows/issues/56).

## Data source

The drawer reads CPA Manager's pre-aggregated summary over HTTP, the same
source KSG Code uses:

```text
GET <baseUrl>/v0/management/quota/summary
Authorization: Bearer <adminKey>
```

Per-provider spend for the Today / Yesterday / 30 Days card comes from the
manager's usage analytics, the source of the panel's Usage Analytics page:

```text
POST <baseUrl>/v0/management/monitoring/analytics
{"from_ms": ..., "to_ms": ..., "include": {"channel_share": true}}
```

Each row's `cost` is summed by `auth_provider_snapshot`, with
`openai-compatible-` prefixes and `-local`/`-native` suffixes folded into the
upstream provider. Today and Yesterday are local calendar days; 30 Days is a
rolling window. The three reads run with every quota refresh (about 0.3 s each
on the live manager); a failed read keeps the last figures and never sets the
drawer's error line.

`baseUrl` and `adminKey` come from
`%LOCALAPPDATA%\caelestia-windows\config\cpa-agents.json` (or
`CAELESTIA_CPA_CONFIG`). A `FileView` reads the file and the `Quota` service
keeps the values in memory only; the key, the response body, emails and account
ids are never logged. No Python process, ledger download or local usage-record
store is involved.

The response is mapped onto the original drawer model:

| Summary | Drawer |
| --- | --- |
| `providers[]` | one section (header and card) per provider, in the original codex-first order |
| `providers[].accounts[]` | one block of meters per account inside the provider card |
| `accounts[].windows[]` | quota meters (`usedPercent`, `resetAt` countdown) |
| window id with a model scope (`seven-day-opus`, …) | extra meters after the account's main windows |
| `todayCostUsd` | the spend card's Today total until analytics answer |
| analytics `channel_share[].cost` | the spend card's donut and legend |
| `providers[].status/error`, `accounts[].status/error` | saved, disabled, reconnect and error notices |

`remainingPercent` is used only when `usedPercent` is absent. Windows whose
label already contains `·` keep their scope; otherwise a scoped id such as
`seven-day-opus` is rendered as `Opus · Weekly`. That is how the original
collector classified model-scoped limits; the redesigned drawer retains those
metric semantics.

Refresh runs on `refreshIntervalMs` from `quota.json`, never faster than the
manager's `ttlMs`, with one request in flight and a 15 s abort. On failure the
last good summary stays on screen with an error in the footer. The last good mapped summary
(display names, windows, status, cost and per-provider spend only; no endpoint, key, email, account
id or manager error text) is cached at `<cache>/quota-summary.json` so the
drawer shows the previous reading instantly on start.

## What is staged

| Source here | Staged as |
| --- | --- |
| `modules/quota/{Wrapper,Content,QuotaMeter,QuotaSpend,QuotaToolTip}.qml` | `modules/quota/` |
| `modules/quota/QuotaLogic.js` | `modules/quota/QuotaLogic.js` |
| `services/Quota.qml` | `services/Quota.qml` |
| `services/QuotaConfig.qml` | `services/QuotaConfig.qml` |
| `scripts/cpa_keepalive.py` | `scripts/cpa_keepalive.py` |
| `assets/provider-icons/*` | `assets/provider-icons/*` |

The Windows drawer follows [OpenUsage](https://github.com/robinebers/openusage)'s
layout: a spend card (range tabs, donut, legend), then every provider as a header and one card of
label/bar/reset meters with a pace tick, above a status and keepalive footer;
the tooltip and data semantics are adapted from the overlay.

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
  original fallbacks.
- **Opt-in.** A local `FileView` existence check of `cpa-agents.json` decides
  whether the drawer is enabled. Missing config means no request, no error and
  a disabled drawer.
- **Keepalive.** The bolt button still calls the upstream `cpa_keepalive.py`
  helper, unchanged. It sends real keepalive traffic only when pressed and
  needs Python plus `CPA_API_KEY` (or the Linux `environment.d/cpa.conf`
  fallback); quota display itself no longer needs either.
- **Empty states.** No CPA config shows "Not configured. Add cpa-agents.json to
  the shell config folder." in the muted colour; an unreachable endpoint shows
  one saved-data line; a valid summary with no accounts shows the original
  empty text.

## What the summary replaced

The ported Python collector also produced per-account token ledgers and a
saved-record store. The management summary does not contain that data, so the
following are gone rather than approximated:

- the per-model "tokens by model" table;
- the today token/request count (the footer shows `todayCostUsd`);
- account balance, cooldown timestamps, pool/ledger metadata and
  `lastUsedAt`;
- `windows/quota/scripts/cpa_usage.py`, `read_records.py` and the
  `state\omarchy\agents\usage` records.

Per-account quota windows, reset times, plan labels, statuses and provider
marks are all still present.

## Run the smoke

```powershell
powershell -NoProfile -File windows/scripts/Test-Quota.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot C:\b-quota
```

The harness stages the production graph and runs `QuotaSmoke.qml` offscreen in
three isolated profiles:

1. **configured** - a local synthetic CPA stub (`fixtures/stub_cpa.py`) serves
   the summary shape with three providers, five accounts and one model-scoped
   window. The drawer opens on Claude, the meters (including the model-scoped one),
   spend card and provider sections render, and dark plus light-palette screenshots are saved.
2. **offline** - the endpoint refuses connections. With the configured run's
   cache copied in, the saved rows stay visible behind the single error line;
   the run must settle without hanging.
3. **unconfigured** - no config; no request and the drawer stays disabled.

It writes `result.json`, per-mode logs, screenshots and the two profile caches
under a disposable `%TEMP%\caelestia-quota-smoke\<run>` directory. Logs,
screenshots and caches are intentionally not committed.

## Verification limits

- The smoke uses synthetic CPA data, not a real management server. Live response
  shapes beyond the captured schema, real provider labels, the exact set of
  model-scoped window ids, provider icon appearance at every DPI and the hover
  feel on the live desktop still need a live check.
- The keepalive script keeps upstream's ports and endpoints. It was not pressed
  in the smoke: it sends real traffic and needs CPA inference reachability plus
  `CPA_API_KEY`.
- The light screenshot uses a fixed Material 3 baseline palette fixture, not a
  generated wallpaper scheme.
- The provider icon marks are copied from the custom overlay. They are
  third-party brand marks; verify redistribution terms before publishing.
