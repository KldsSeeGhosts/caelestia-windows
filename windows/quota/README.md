# CPA quota drawer

Windows port of the CPA quota panel from the author's Linux Caelestia overlay
(not public). The Windows implementation and its production staging map are
included in this repository.

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
ids are never logged. Summary mode involves no Python process, ledger download
or local usage-record store; hub mode (below) adds one Python helper.

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

## Hub mode (CLIProxyAPI)

Stock CLIProxyAPI has no `quota/summary`, and CPA Manager's summary has no
token history, per-model tokens or limit resets. Hub mode reads them from the
hub's own logins, the way OpenUsage treats CLIProxyAPI as a token broker:

```text
GET  <baseUrl>/v0/management/auth-files     the hub's logins
POST <baseUrl>/v0/management/api-call       {auth_index, method, url, header, data}
```

`api-call` sends the request upstream as that login, with the hub's own token
in place of `$TOKEN$`, and answers `{status_code, header, body}`. The token
never reaches this PC. Codex, Claude and Antigravity logins are supported;
other logins are skipped.

Hub mode runs when:

- `quota/summary` answers 404 (stock CLIProxyAPI). The hub is then the only
  source, and the summary is asked again only on **Refresh now** or a new
  endpoint;
- **Detailed usage via CLIProxyAPI** is on (Nexus > Services, under the Agent
  usage panel switch; `windows.quota.cpaHub` in `shell.json`, off when absent).
  With CPA Manager this adds history, Top Models and Limit Resets to the
  summary's rows; the helper starts once the summary has accepted the key. A
  plain http `baseUrl` on the local network or Tailscale, which the summary
  read refuses, is read through the hub only with this switch on; switching it
  off stops the helper.

The reads are done by `providers/quota_providers.py`, a standard-library
Python helper started as `py -3 -I quota_providers.py serve`. It runs only
while the Agent usage panel is on and is killed when the panel goes off, like
Keepalive. QML talks to it in JSON lines over stdin and stdout. `baseUrl` and
`adminKey` come from the same `cpa-agents.json` and reach the helper over
stdin only, never its command line or environment.

| Provider | Every pass | Hourly |
| --- | --- | --- |
| Codex | `wham/usage`: 5-hour, Weekly, Spark windows, plan, reset-credit count | reset-credit expiries; 30 days of `analytics/daily-workspace-usage-counts` (tokens by day and model) |
| Claude | `oauth/usage`: 5-hour, Weekly, Sonnet and model-scoped weekly windows; plan from `oauth/profile` on the first read | `oauth/profile` and the reset grants (`cedar_ember`), in a pass of their own |
| Antigravity | `retrieveUserQuotaSummary`: Gemini 5-hour and weekly, Argon weekly, Claude 5-hour and weekly | `loadCodeAssist`: plan and project |

Rules, after OpenUsage:

- Calls to the hub go one at a time. A 401 or an IP-ban answer stops every
  further management request with that key, from the drawer, the helper and
  Keepalive alike, until `adminKey` changes: CLIProxyAPI bans an IP for 30
  minutes after five wrong keys. The refusal is kept in the drawer's cache as a
  salted SHA-256 fingerprint of the key (never the key), so panel toggles,
  reloads and restarts send nothing either. The footer then reads "CLIProxyAPI
  rejected the management key. Update cpa-agents.json."
- The key goes over https anywhere. Over plain http it goes only when every
  address the host resolves to is on this PC (`127.0.0.0/8`, `::1`), a private
  network (`10/8`, `172.16/12`, `192.168/16`) or Tailscale (`100.64.0.0/10`,
  `fd7a:115c:a1e0::/48`). Names such as `.local` or `.ts.net` are not trusted
  on their own, and link-local and other unique-local addresses are refused.
  The helper and Keepalive connect only to the addresses they checked, in the
  order they resolved, trying the next when a connection fails (so `localhost`
  works whether `::1` or `127.0.0.1` answers first). A second DNS answer cannot
  redirect the key. No redirect or proxy is followed.
- A login with no email or name is shown as "Codex account 1" and so on,
  numbered by its id inside the helper; the id itself never leaves it.
- A login is dropped only after two listings in a row lack it. The list is
  read at start, hourly and on **Refresh now**. The same login listed twice is
  read once.
- Scheduling: the helper keeps a deadline per account and reports the
  earliest; the drawer arms one single-shot timer for it, so nothing polls. An
  account is read automatically at most every 300 s, whatever
  `refreshIntervalMs` says. Failures back off from 5 minutes, doubling to an
  hour, or longer when `Retry-After` asks. **Refresh now** skips accounts read
  in the last 60 s.
- Claude allows about 30 usage reads an hour per login, shared with Claude
  Code. Each login gets one read per pass, and its 429 window is saved in the
  cache so a restart does not send into it.
- It is read-only. Each reset's **Use** button stays a stub, and no consume or
  reset endpoint is ever called.

**Merging.** The helper derives CPA Manager's opaque account ID from the auth
inventory metadata, so masked summary rows match without exposing credential
names or emails. An exact opaque ID takes precedence over a shared email;
legacy summaries can match an unambiguous email or account ID instead.
A matched login adds its history and resets to that row instead of showing
twice. The summary's windows and status stay. Every other hub login is
an account of its own. The provider card's Today, Yesterday and Last 30 Days
rows show spend when the manager reports it and hub tokens otherwise; their
detail adds the token mix (Input, Cache Read, Output) and Top Models. Days are
UTC dates, as the reports are.

**Privacy.** The drawer gets an email's local part as the label, never the
address or an account id. Accounts are keyed by a short HMAC of the provider
and identity under the management key. The cache adds only windows, plan,
reset expiry times, daily token aggregates by model name, and the Claude 429
windows by that tag. It never holds keys, tokens, emails, ids or response
bodies. The helper's stderr carries only short diagnostics, with every known
secret redacted, and the drawer reads it without showing or logging it.

**Terms of service.** Hub mode calls undocumented internal endpoints
(ChatGPT's `wham`, Anthropic's `oauth/usage`, Google's `v1internal`) that may
change or be blocked at any time. To be answered at all, it sends the headers
of the vendors' own clients: Claude Code's `User-Agent` (reset grants are
returned only to it), the Codex desktop client's `originator` and
`OpenAI-Beta` headers on the reset-credit list, and Antigravity's
`User-Agent`. Using a vendor's client identity from a third-party tool may be
against that vendor's terms. Leave hub mode off if that matters to you. The
provider logic is ported from OpenUsage (MIT); see
`providers/THIRD_PARTY_NOTICES.md`. This drawer is not affiliated with or
endorsed by OpenUsage.

## What is staged

| Source here | Staged as |
| --- | --- |
| `modules/quota/{Wrapper,Content,QuotaBar,QuotaBreakdown,QuotaLogo,QuotaMenu,QuotaMeter,QuotaPopover,QuotaPriorityRow,QuotaResets,QuotaSegments,QuotaToolTip,QuotaValueRow}.qml` | `modules/quota/` |
| `modules/quota/QuotaLogic.js` | `modules/quota/QuotaLogic.js` |
| `services/Quota.qml` | `services/Quota.qml` |
| `services/QuotaConfig.qml` | `services/QuotaConfig.qml` |
| `services/QuotaHub.js` | `services/QuotaHub.js` |
| `providers/{quota_providers,core,hub,scheduler,codex,claude,antigravity}.py`, `providers/THIRD_PARTY_NOTICES.md` | `providers/` |
| `scripts/cpa_keepalive.py` | `scripts/cpa_keepalive.py` |
| `assets/README.md` | `assets/provider-icons/README.md` |

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
total, plus a token mix and Top Models when hub mode reports them (CPA's
analytics give a cost per provider only).
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

Validate layout at the 384x520 default, the 280 dp minimum width and a short
280x300 drawer. Include long labels, 0% left, stale, reconnect, disabled,
unreported and monthly-only accounts. Native DPI, keyboard, pointer and touch
behavior require installed-shell checks, not a loading smoke.

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

## Validation and limits

The [public production smoke](../NATIVE-BUILD.md#smoke) keeps quota disabled.
It does not contact a management server or establish configured drawer behavior.
Use a disposable profile and synthetic account data for separately authorized
checks. Cover configured, offline, unconfigured and disabled states, summary
and hub reconciliation, keyboard/menu traversal, cache recovery, panel-disable
cancellation and authentication refusal. A 401 or ban must stop further calls
with that key, including refresh and keepalive.

- Live response shapes, real provider labels, model-scoped window ids, provider
  icon appearance at every DPI and hover behavior need a live check.
- The keepalive script requires an explicit HTTPS `inferenceUrl` (or
  `CPA_INFERENCE_URL`) when `baseUrl` is remote, or uses loopback when
  `baseUrl` is local. It sends real traffic and
  needs CPA inference reachability plus `CPA_API_KEY`.
- The provider response shapes follow OpenUsage's mappers, not a guarantee of a live hub's behavior. The real
  `auth-files` listing, Claude grant eligibility and Antigravity buckets still
  need a live check.
- Public source and packages omit third-party provider brand marks because
  redistribution permission was not established. QuotaLogo uses its existing
  two-letter provider-name fallback; layout, quota values and labels are unchanged.
