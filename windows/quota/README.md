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
| `todayCostUsd` | kept in the service and its cache; the drawer shows each provider's own spend instead |
| analytics `channel_share[].cost` | the provider card's Today / Yesterday / Last 30 Days value rows |
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
| `modules/quota/{Wrapper,Content,QuotaBar,QuotaLogo,QuotaMenu,QuotaMeter,QuotaPriorityRow,QuotaSegments,QuotaToolTip,QuotaValueRow}.qml` | `modules/quota/` |
| `modules/quota/QuotaLogic.js` | `modules/quota/QuotaLogic.js` |
| `services/Quota.qml` | `services/Quota.qml` |
| `services/QuotaConfig.qml` | `services/QuotaConfig.qml` |
| `scripts/cpa_keepalive.py` | `scripts/cpa_keepalive.py` |
| `assets/provider-icons/*` | `assets/provider-icons/*` |

The Windows drawer follows [OpenUsage](https://github.com/robinebers/openusage)'s
panel in Caelestia's Material 3 tokens, so it takes the wallpaper scheme in dark
and light. Top to bottom:

1. a **Priority | All Usage** switch: a full-width pill track with a raised pill
   that slides under the chosen segment. The choice lasts while the shell runs
   and starts on **All Usage**;
   - **All Usage** is one scroll of provider sections, in the original
     codex-first order, with no provider strip;
   - **Priority** is one card listing each account's single most constrained
     window (least `% left` first, across all providers), with the provider logo
     and account label. It answers "what runs out first". Accounts with no
     reading are left out; their notice is in All Usage;
2. a section per provider: a large bold title with the provider logo on the
   right, then a card (`m3surfaceContainer`, a hairline `m3outlineVariant`
   border). Each account has a muted label with its plan as a small chip on the
   right, then one **grid row per window**: label, a thick rounded bar showing
   `% left`, the `%` and the reset countdown (`4h 10m`, `6d 23h`). The bar column
   is 40% of the card (30% at the 280 dp minimum, where the label elides), and
   every row in the drawer shares the same columns. A bar turns to the error
   colour at 10% left or less; nothing else is colour coded. Accounts are
   separated by space, not rules. A stale, reconnect, disabled or unreported
   account keeps its notice as one muted (or error) row above its meters.
   Windows are never invented: a provider that reports only `API`/`Auto` or a
   monthly window shows exactly those. The card ends with that provider's
   Today / Yesterday / Last 30 Days spend from the analytics (API-equivalent
   cost, a range appears once it has loaded), as label and value rows;
3. a footer pinned to the bottom that the content fades under: "Next update in
   Xm" (or the updating or error status) on the left and a round `...` button on
   the right. The button opens a small menu with **Refresh now** and
   **Keepalive**.

Tab reaches the two segments, the scrolling content (Up, Down, Page Up, Page
Down, Home and End scroll it) and the `...` button. In the menu Up and Down move,
Return, Enter and Space act, Escape closes it and returns to the button, and Tab
leaves it. Every meter keeps an accessible name such as "Claude, Weekly, 64
percent left, resets in 4 hours 53 minutes". Tooltips stay only where they add
information: a truncated label, the exact reset time, and what the spend is.
The tooltip and data semantics are adapted from the overlay.

`windows/scripts/Test-Quota.ps1` checks this offscreen: the configured stub at
the 384x520 default, the 280 dp minimum width and a short 280x300 drawer, with
the column alignment (one x for every bar, `%` and reset), the Priority order
and the 10% error colour asserted; a `states` scenario (long account name, 0%
left, stale, reconnect, disabled and unreported accounts, `API`/`Auto` and
monthly-only providers); the offline, unconfigured and `disabled` profiles.
`windows/scripts/Test-QuotaProviderKeyboard.ps1` drives the real drawer by
keyboard and pointer. Native DPI, pointer and touch checks are separate.

The drawer is wired into the shared drawer graph:

- `components/ScreenState.qml` gains `quota`.
- `modules/drawers/{ContentWindow,Interactions,Regions}.qml` add the close
  paths, hover area, input region and blob deformation. `Interactions.qml` and
  `Regions.qml` skip the drawer while `panels.quotaEnabled` is false.
- `windows/shell/adapters/modules/drawers/Panels.qml` imports
  `qs.modules.quota`, exposes `quota`, and anchors `Quota.Wrapper` top-right.

There is no bar entry and no default keybind, matching the Linux overlay.

## Windows adaptations

- **Config.** Upstream reads `GlobalConfig.quota` from a patched C++ config
  plugin. This port reads the same schema from an optional `quota.json` in the
  shell config directory, so no plugin rebuild is needed. Defaults match the
  original fallbacks.
- **Opt-in.** A local `FileView` existence check of `cpa-agents.json` decides
  whether the drawer is enabled. Missing config means no request, no error and
  a disabled drawer.
- **Agent usage panel setting.** Nexus > Services has an **Agent usage panel**
  switch, stored as `windows.quota.enabled` in `shell.json` (on when absent).
  Off, the drawer never opens, its hover and input region are gone, so nothing
  deforms, and the service reads no key, makes no request and runs no timer; an
  open drawer closes and a request in flight is aborted. It applies live. On
  again, the last cached reading is there at once. It only ever narrows what
  `cpa-agents.json` and `quota.json` allow; it never enables the panel alone.
- **Keepalive.** The footer menu's **Keepalive** entry calls `cpa_keepalive.py`, which resolves the
  inference endpoint from `--inference-url`, `CPA_INFERENCE_URL`, or
  `inferenceUrl` in `cpa-agents.json` (falling back to loopback
  `http://127.0.0.1:8317/v1/chat/completions` only when `baseUrl` is loopback).
  It sends real keepalive traffic only when pressed and needs Python plus
  `CPA_API_KEY` (or the `environment.d/cpa.conf` fallback); quota display
  itself no longer needs either.
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
isolated profiles:

1. **configured** - a local synthetic CPA stub (`fixtures/stub_cpa.py`) serves
   the summary shape with three providers, five accounts, one model-scoped
   window and one window at 7% left. The drawer opens on All Usage; the
   sections, shared columns and spend rows are checked, then Priority and the
   footer menu, and dark, light, Priority and menu screenshots are saved.
2. **states** - long names, 0% left, stale, reconnect, disabled and unreported
   accounts, each section checked for what it reports and no more.
3. **offline** - the endpoint refuses connections. With the configured run's
   cache copied in, the saved rows stay visible behind the single error line;
   the run must settle without hanging.
4. **unconfigured** - no config; no request, no input region, and the drawer
   stays disabled.
5. **disabled** - a valid config with the Agent usage panel off: the drawer
   never opens, the input region is empty and no request is made. Switching the
   setting on, off and on again at runtime opens, closes and quiets the drawer
   and keeps the cache.

It writes `result.json`, per-mode logs, screenshots and the two profile caches
under a disposable `%TEMP%\caelestia-quota-smoke\<run>` directory. Logs,
screenshots and caches are intentionally not committed.

## Verification limits

- The smoke uses synthetic CPA data, not a real management server. Live response
  shapes beyond the captured schema, real provider labels, the exact set of
  model-scoped window ids, provider icon appearance at every DPI and the hover
  feel on the live desktop still need a live check.
- The keepalive script requires an explicit HTTPS `inferenceUrl` (or
  `CPA_INFERENCE_URL`) when `baseUrl` is remote, or uses loopback when
  `baseUrl` is local. It was not pressed in the smoke: it sends real traffic and
  needs CPA inference reachability plus `CPA_API_KEY`.
- The light screenshot uses a fixed Material 3 baseline palette fixture, not a
  generated wallpaper scheme.
- Provider logos are shown as shipped (the light or dark variant for the scheme)
  at reduced opacity. A flat `m3onSurfaceVariant` tint is a follow-up: GPU
  effects render nothing in the offscreen harness, so it could not be verified
  there.
- The provider icon marks are copied from the custom overlay. They are
  third-party brand marks; verify redistribution terms before publishing.
