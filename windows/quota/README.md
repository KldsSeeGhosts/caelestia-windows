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
| `modules/quota/{Wrapper,Content,QuotaBar,QuotaBreakdown,QuotaLogo,QuotaMenu,QuotaMeter,QuotaPopover,QuotaPriorityRow,QuotaResets,QuotaSegments,QuotaToolTip,QuotaValueRow}.qml` | `modules/quota/` |
| `modules/quota/QuotaLogic.js` | `modules/quota/QuotaLogic.js` |
| `services/Quota.qml` | `services/Quota.qml` |
| `services/QuotaConfig.qml` | `services/QuotaConfig.qml` |
| `scripts/cpa_keepalive.py` | `scripts/cpa_keepalive.py` |
| `assets/provider-icons/*` | `assets/provider-icons/*` |

The Windows drawer is a port of the menu bar panel of
[OpenUsage](https://github.com/robinebers/openusage) (MIT, Copyright (c) 2026
Robin Ebers). Its structure, spacing, type sizes and weights, Priority rules,
countdown and number formats come from OpenUsage's SwiftUI source; colour comes
from Caelestia's scheme, so it follows the wallpaper in dark and light, and text
uses Caelestia's font. No OpenUsage code or assets are included. Top to bottom,
inside a 12 dp margin:

1. a **Priority | All Usage** switch: a 28 dp capsule track with a raised thumb
   that springs to the chosen segment. The choice lasts while the shell runs and
   starts on **All Usage**;
2. **All Usage** is one scroll of provider sections, in the original
   codex-first order. Each has a 24 dp title row (15 dp semibold, the provider
   mark on the right) and a card (radius 12, `m3surfaceContainer`, a hairline
   border) padded 12 / 8 / 10. Each account has an 11 dp muted caption with its
   plan as a small badge, then one 22 dp **row per window**: label (90 dp
   column), bar, `% left` (52 dp) and the reset countdown (48 dp: `4h 10m`,
   `6d 23h`, `soon`). Every row shares the same columns; below OpenUsage's
   340 dp width the label column gives way so the bar keeps 48 dp. A bar and its
   `%` turn to the warm accent at 30% left or less and to the error colour at
   10% or less. A stale, reconnect, disabled or unreported account carries a
   small warning (or clock) mark in its caption, with the reason in a tooltip
   and its accessible name. Windows are never invented. The card ends with the
   provider's Today / Yesterday / Last 30 Days spend from the analytics
   (API-equivalent cost);
3. **Priority** lists every window at 30% left or less under **Running Out**,
   least left first, each as a 46 dp row with a ring gauge round the provider
   mark, and windows with nothing left under **Used Up**. With nothing low it
   shows **All Clear**; accounts whose usage cannot be read are listed under
   **Needs Attention**. OpenUsage's "burning fast" tier needs a usage pace that
   CPA does not report, and pins and the share card have no counterpart here;
4. a footer under a 1 dp divider: "Next update in Xm" (a click refreshes; or the
   updating or error status) on the left and a round 26 dp `...` button on the
   right. Its menu follows OpenUsage's: the drawer's own **Refresh now**
   (Ctrl+R) and **Keepalive**, a separator, then **Accounts** (Return) and
   **Settings** (Ctrl+,), which close the drawer and open Nexus > Services,
   where the quota switch lives. OpenUsage's Check for Updates, Report an
   Issue, About and Quit are app-level and left out: the shell has its own.

Hovering a spend figure (Today, Yesterday, Last 30 Days) for 400 ms opens
OpenUsage's breakdown detail with its arrow on the figure: the range and its
total, plus a token mix and Top Models when a source reports them (CPA's
analytics give a cost per provider only, so today those sections stay hidden).
An account whose data carries reset credits gets a **Limit Resets** row whose
detail is the numbered list of resets with their times and countdowns; its
**Use** button is a stub until provider integrations land, and no reset is ever
claimed. A click opens a detail until Escape or another click. OpenUsage's
copy-screenshot buttons are not ported.

Tab reaches the two segments, the scrolling content (Up, Down, Page Up, Page
Down, Home and End scroll it) and the `...` button. In the menu Up and Down move,
Return, Enter and Space act, Escape closes it and returns to the button, and Tab
leaves it. Every meter keeps an accessible name such as "Claude, Weekly, 64
percent left, resets in 4 hours 53 minutes". Tooltips stay only where they add
information: a truncated label, the exact reset time, and what the spend is.
The tooltip and data semantics are adapted from the overlay.

`windows/scripts/Test-Quota.ps1` checks this offscreen: the configured stub at
the 384x520 default, the 280 dp minimum width and a short 280x300 drawer, with
OpenUsage's column grid and row heights, the column alignment (one x for every
bar, `%` and reset), the Priority rule and order and the error colour asserted; a `states` scenario (long account name, 0%
left, stale, reconnect, disabled and unreported accounts, `API`/`Auto` and
monthly-only providers); the offline, unconfigured and `disabled` profiles;
and a `keepalive` run that switches the panel off while a fake helper runs.
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
  itself no longer needs either. Switching the panel off ends a running keepalive
  helper too.
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
6. **keepalive** - a fake helper process stands in for `cpa_keepalive.py` and
   would write a marker file three seconds later. The panel is switched off
   while it runs: the helper must be gone and the marker never written.

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
- Provider logos are tinted flat `m3onSurfaceVariant` through the icon colour of
  a decorative Qt Controls button (no GPU effect, so the offscreen screenshots
  show the real tint). Native DPI rendering still needs a live check.
- The provider icon marks are copied from the custom overlay. They are
  third-party brand marks; verify redistribution terms before publishing.
