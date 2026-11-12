# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io),
certificate by [SignPath Foundation](https://signpath.org).

This policy covers the Windows x64 releases published from
[KldsSeeGhosts/caelestia-windows](https://github.com/KldsSeeGhosts/caelestia-windows).
The project is licensed under [GPL-3.0](../../LICENSE). SignPath Foundation's
conditions are at [signpath.org/terms](https://signpath.org/terms).

**Current state.** No release is signed. There is no stable release, no signing
credential and no signing job in this repository. Development and preview
packages are unsigned. This page records the policy the project intends to apply
once a signing pipeline exists, and the work that pipeline still needs is in
[SIGNING-ROADMAP.md](SIGNING-ROADMAP.md). Do not describe any current download
as signed.

A signature proves which publisher produced a binary and that the signed bytes
are the ones that publisher released. It does not certify that the software is
free of defects, and it does not replace the manifest digests, source provenance
or Windows qualification described in [INSTALL-RELEASE.md](INSTALL-RELEASE.md)
and [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md).

## Release channels

| Channel | Reference | Signed | Notes |
| --- | --- | --- | --- |
| Development | `vX.Y.Z-development` | No | Eligible green `main` pushes publish history-derived plain versions. |
| Preview | `vX.Y.Z-preview` | No | Promotion of identical tested development artifacts. Historical `v0.1.0-preview.2` keeps its original tag. |
| Stable | `vMAJOR.MINOR.PATCH`, `MAJOR >= 1` | Intended | My plan is that stable releases will be signed through SignPath Foundation once the pipeline exists. No stable release exists today. |

The table describes this project's own publisher signature. Deployed Qt DLLs
carry Qt's signature in every channel; that is a vendor signature, not one from
this project.

The channel classification is implemented in
[Caelestia-Signing.ps1](../scripts/Caelestia-Signing.ps1)
(`Get-CaelestiaReleaseChannel`). It is used by the standalone verifier and its
fixtures only; no CI job runs it. A tag that is not an unqualified core of 1.0.0
or newer is never treated as stable. Promotion to the Nexus `stable` channel
already requires the alias to equal the core and refuses a 0.x core, so the tag
grammar and the channel metadata agree.
Legacy development and preview tags retain their historical classification.
Only version/tag classification changes here, not signing policy or keys.

Development and preview releases stay unsigned on purpose. They change with
every push, they are not manual release decisions, and signing each one would
exhaust the approval process that makes a signature meaningful. If a preview is
blocked by Smart App Control, antivirus or an organizational policy, do not
disable that protection. Wait for a stable release or build from source.

## What a stable release would sign

Only files this repository builds. The reviewed set is
[windows/release/signing-inventory.json](../release/signing-inventory.json):
38 PE files and 18 PowerShell files. The verifier fails if the bundle is missing
one of them, or contains a first-party file that is not in the inventory.

| Signed artifact | Built from | Kind |
| --- | --- | --- |
| `payload/caelestia-capture.exe` | [windows/capture](../capture) (maintained first-party capture source, MIT) | PE, Authenticode |
| `payload/DesktopTakeover.dll` | [windows/scripts/DesktopTakeover.cs](../scripts/DesktopTakeover.cs), compiled during native build | PE, Authenticode |
| `payload/caelestia-*.dll` | Caelestia helper DLLs built from this repository | PE, Authenticode |
| `payload/qml/Caelestia/**/caelestia-*.dll` | Caelestia QML plugin modules built from this repository | PE, Authenticode |
| `Install-CaelestiaRelease.ps1` | [windows/scripts/Install-CaelestiaRelease.ps1](../scripts/Install-CaelestiaRelease.ps1) | PowerShell, Authenticode |
| 17 `payload/*.ps1` scripts | The maintenance, launcher, update and uninstall scripts | PowerShell, Authenticode |

Every signature would be SHA-256 Authenticode with an RFC 3161 timestamp. A
stable release would fail verification if any listed file is unsigned, has an
invalid signature, has no timestamp, or is signed by a publisher other than the
exact certificate subject recorded for SignPath Foundation.

## What is not signed, and why

| Artifact | Why it is not signed with the project certificate |
| --- | --- |
| `payload/qs.exe` | It is a build of the modified Quickshell fork. SignPath Foundation's rules for a modified upstream project require the upstream project to publish signed builds; Quickshell ships no signed Windows binaries. The file's version resource also identifies Quickshell, not this project. It stays an unsigned upstream binary inside a signed package, which the same rules permit. |
| `payload/m3shapes.dll`, `payload/qml/M3Shapes/**` | Third-party [soramanew/m3shapes](https://github.com/soramanew/m3shapes), pinned as a submodule and licensed Apache-2.0. Only its maintainers may sign it. |
| `payload/Qt6*.dll`, `payload/plugins/**`, `payload/qml/**` outside `Caelestia` and `M3Shapes` | Qt's own binaries keep Qt's signature. They are verified, never re-signed. |
| `Install.cmd` | A batch file. Authenticode has no signature format for it. |
| The release ZIP | The ZIP is not signed. Its SHA-256 and the manifest SHA-256 are published beside it. |
| `release.json`, `INSTALL-RELEASE.md`, licences, fonts, SBOMs, QML files | Data, not executable code. |

[windows/signpath/caelestia-windows-stable.xml](../signpath/caelestia-windows-stable.xml)
is a draft artifact configuration for the intended signed set. It is not
registered with SignPath and no signing service consumes it. A future signing
pipeline must verify the same ownership rules independently.

## Build and signing status

There is no signing pipeline. In particular:

- `.github/workflows/windows-build.yml` does not sign anything and does not
  verify publisher signatures. The development publisher creates a tag on every
  green `main` push, and those tags must never start a signing run.
- There is no stable assembly and publication contract. `New-CaelestiaRelease.ps1`
  currently rejects stable release IDs, and Nexus promotion keeps the development
  bundle bytes. A stable signed bundle cannot be produced by relabelling a
  development artifact; it must be assembled and signed at the stable tag with
  its own provenance.
- [Test-AuthenticodeSignatures.ps1](../scripts/Test-AuthenticodeSignatures.ps1)
  is a standalone verifier. It checks the reviewed inventories, the bundle
  manifest and the signatures of an extracted bundle. No CI job calls it.
- No SignPath API token, certificate, private key or signing credential exists
  in this repository or in its Actions configuration.

The requirements for a real pipeline are listed in
[SIGNING-ROADMAP.md](SIGNING-ROADMAP.md). Signing activates only after that work
is done, my SignPath application is accepted and the service is
configured.

## Team roles

SignPath Foundation requires the project team to name the people behind three
roles. I am the sole maintainer today and hold all three, and I'll keep
this list current as contributors join.

| Role | Who | Responsibility |
| --- | --- | --- |
| Authors | [KldsSeeGhosts](https://github.com/KldsSeeGhosts); repository [CODEOWNERS](../../.github/CODEOWNERS) | May change source and build scripts without an additional review. |
| Reviewers | [KldsSeeGhosts](https://github.com/KldsSeeGhosts) | Reviews every proposed change from someone who is not a committer. |
| Approvers | [KldsSeeGhosts](https://github.com/KldsSeeGhosts) | Decides whether a specific release may be signed. I am the single approver. |

Every signing request would need a manual approval. The approver would confirm
that the request belongs to the exact tested stable release, that the workflow
run is the trusted producer run, and that the signing request is not a re-run of
a superseded build. A rejected or denied request is not retried with relaxed
settings.

All team members use multi-factor authentication for both GitHub and SignPath.
That is a condition of the SignPath Foundation subscription, not a local
convenience.

## Verifying a release

Current development and preview releases are unsigned. For them, verify the ZIP
and manifest SHA-256 values as described in [INSTALL-RELEASE.md](INSTALL-RELEASE.md).
A publisher check is not available and the installer does not pretend to provide
one.

Once a signed stable release exists, these steps apply:

1. Download the ZIP and its `.zip.sha256` from the project's
   [releases page](https://github.com/KldsSeeGhosts/caelestia-windows/releases),
   never from an unrelated mirror.
2. Check the ZIP digest: `Get-FileHash -Algorithm SHA256 <zip>`.
3. Extract the whole ZIP. In Windows PowerShell, check a signed file:

   ```powershell
   Get-AuthenticodeSignature .\payload\caelestia-capture.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
   ```

   `Status` must be `Valid`, the signer must be the recorded SignPath Foundation
   subject, and a timestamp must be present.
4. Verify the whole bundle with the project's own check from a reviewed checkout:

   ```powershell
   powershell.exe -NoProfile -File windows\scripts\Test-AuthenticodeSignatures.ps1 `
       -BundleRoot <extracted-bundle> -Channel stable `
       -ExpectedSignerSubject '<exact certificate subject>'
   ```

   It first checks the reviewed file set against
   `windows/release/signing-inventory.json` and
   `windows/release/vendor-privacy-review.json`, then confirms that Qt DLLs keep
   a valid signature from the exact reviewed Qt certificate subject and that no
   third-party file was re-signed with the project certificate. A Qt certificate
   renewal fails with `unexpected-signer` until a reviewed change records the new
   literal subject.
5. Run the installer with `-ExpectedManifestSha256` from trusted release
   metadata, as described in [INSTALL-RELEASE.md](INSTALL-RELEASE.md).

## SmartScreen, Smart App Control and antivirus

Windows treats signed and unsigned software differently, and a signature only
changes part of that behavior.

- A valid signature supplies publisher identity: Windows shows who signed the
  bytes. SmartScreen reputation is separate. A newly signed app can still trigger
  the "Windows protected your PC" prompt, which calls the app an "unrecognized
  app" until Microsoft's reputation data includes it. That prompt describes the
  app's reputation, not an unknown signer. A signature does not grant
  reputation.
- Smart App Control only allows software it considers safe. A valid signature
  helps, but Smart App Control also weighs its own reputation data. Because
  `qs.exe` is not signed by this project, Smart App Control can still block a
  stable release on a machine where it is enforced. Do not disable Smart App
  Control, antivirus or an organizational policy to work around that.
- Antivirus and enterprise policies are independent of Authenticode. A signature
  does not whitelist a binary.
- The per-user installer runs its own PowerShell process with
  `-ExecutionPolicy Bypass`. That is a process-scoped execution-policy choice,
  not a signature, and it changes no persistent policy.

## Privacy

This section is the privacy statement referenced by the code signing policy. It
replaces the blanket sentence that nothing leaves the machine: the installed
shell and its staged scripts make the automatic and opt-in requests below and no
others. The shell sends no telemetry. Automatic shell requests include no local
profile settings, window titles, notification contents or clipboard data.
Notification links and clipboard items leave the machine only when the user
explicitly opens one, and they then go to the destination the user chose. Each
row states whether the transfer is automatic while a feature is active, opt-in,
or a user action.

| Service | When it is contacted | Data sent | Privacy policy |
| --- | --- | --- | --- |
| CPA Manager / CLIProxyAPI management endpoint from `cpa-agents.json` | Opt-in through the config file, then automatic while the Agent usage panel is on: the summary request runs as the endpoint loads and on each refresh (`windows/quota/services/Quota.qml:668`), and the spend requests run after the summary accepts the key. Refresh now skips the wait. The file's content is not read and in-flight requests are aborted while the panel is off. | The configured management key in `Authorization: Bearer`, the requested summary or analytics range and fields, ordinary request headers and the source IP address. The summary and spend reads use HTTPS, or plain HTTP only when `baseUrl` is loopback; the QML transport refuses any other plain-HTTP host (`Quota.qml:574`). The response carries account labels, quota windows, reset times and spend. No local profile data is sent. | No project-run service: the endpoint is the user's own CPA Manager or CLIProxyAPI instance, so its operator's policy applies. |
| OpenAI (Codex) through the CPA endpoint | Automatic in hub mode when `quota/summary` answers 404 (stock CLIProxyAPI), or opt-in with Nexus > Services > Detailed usage via CLIProxyAPI (`windows.quota.cpaHub`), while the panel is on. The helper lists the hub's logins and sends usage reads to `chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits` and the daily usage report through the hub's `api-call` tunnel (`windows/quota/providers/codex.py`, `hub.py`). | The management key and auth index go to the configured CPA endpoint. That management transport uses HTTPS, or plain HTTP to loopback, a checked RFC 1918 address or Tailscale when Detailed usage is on (or to loopback for the stock 404 fallback). `hub.py:85` resolves the host and requires every address to pass before the key is sent. The hub substitutes its stored OpenAI token (`$TOKEN$`) and forwards the query, so the token never reaches this PC. The request carries the usage query, the ChatGPT account id header when the login supplies one, and OpenAI client headers. | [OpenAI privacy policy](https://openai.com/policies/privacy-policy/) |
| Anthropic (Claude) through the CPA endpoint | The same hub-mode trigger. `claude.py` reads `api.anthropic.com/api/oauth/usage`, `api/oauth/profile` and the reset-grant read (`cedar_ember`). | The management key goes to the configured CPA endpoint over the same checked transport, with the provider token kept by the hub. The forwarded query carries the usage or profile request and a Claude Code user agent. | [Anthropic privacy policy](https://www.anthropic.com/legal/privacy) |
| Google (Antigravity) through the CPA endpoint | The same hub-mode trigger. `antigravity.py` reads `cloudcode-pa.googleapis.com` and `daily-cloudcode-pa.googleapis.com` (`retrieveUserQuotaSummary`, `loadCodeAssist`). Only Keepalive, below, uses the sandbox host. | The management key goes to the configured CPA endpoint over the same checked transport, with the Google token kept by the hub. The forwarded query carries quota and plan reads and an Antigravity user agent. | [Google privacy policy](https://policies.google.com/privacy) |
| OpenAI, Google and Z.AI through the CPA inference endpoint | User action only: the drawer's Keepalive menu entry runs `scripts/cpa_keepalive.py`. Before any inference it reads `GET /v0/management/auth-files` with the management key to list the enabled logins (`cpa_keepalive.py:273`), even when the later inference succeeds. That management read, and any fallback `api-call`, use HTTPS, or plain HTTP to loopback, a checked RFC 1918 address or Tailscale. The action does not require Detailed usage: `Quota.qml:268` checks only that the panel is configured, enabled and not refused, so `hub.py:85` permits the private-network plain-HTTP addresses on its own. It then sends one real chat completion per enabled login (`gpt-5.6-luna`, `gemini-3.7-flash`, `glm-5.3-flash`) to the inference endpoint from `--inference-url`, `CPA_INFERENCE_URL` or `inferenceUrl`, or to loopback `127.0.0.1:8317` when `baseUrl` is loopback. If the completion cannot run, it falls back to management reads through the CPA endpoint: `chatgpt.com` usage, the Google quota and model URLs including `daily-cloudcode-pa.sandbox.googleapis.com`, or `https://api.z.ai/api/anthropic/v1/messages` (or the login's own `base_url`). | The management key in `Authorization: Bearer` to the configured CPA endpoint for `auth-files` and any fallback `api-call`, together with the auth index and query. The inference key from `CPA_API_KEY` (or the `environment.d/cpa.conf` fallback) goes to the inference endpoint over HTTPS, or over plain HTTP only to loopback (`cpa_keepalive.py:112`), with the literal prompt `ping`, the model name, `max_tokens` 8 or 16, and the source IP address. Provider tokens stay in the hub, except that a Z.AI login exposing `access_token` in the auth inventory has that token passed back to the configured CPA endpoint in the `api-call` envelope. Nothing is sent until the user chooses Keepalive, and switching the panel off stops a running helper. | [OpenAI privacy policy](https://openai.com/policies/privacy-policy/), [Google privacy policy](https://policies.google.com/privacy), [Z.AI privacy policy](https://docs.z.ai/legal-agreement/privacy-policy) |
| ipapi.co (Kloudend, Inc.) | Automatic: a weather surface loads (the dashboard tab or the lock screen) and `services.weatherLocation` is blank. The shell waits 15 minutes after a successful lookup before asking again, and backs off after a rate limit (`services/Weather.qml:57`). | The source IP address and ordinary HTTPS request headers. The response supplies approximate latitude, longitude and city. The shell shows the returned city directly and does not look it up again. No account or profile data is sent. | [ipapi.co/privacy](https://ipapi.co/privacy/) |
| OpenStreetMap Nominatim | Automatic only when `services.weatherLocation` is a coordinate pair and that exact pair is not already in the local city cache (`services/Weather.qml:50,175`). A configured city never calls it, and a blank location never does. | Coordinates, preferred language (`accept-language`) and a `User-Agent` with the shell version. The server also sees the source IP address. | [OpenStreetMap Foundation privacy policy](https://osmfoundation.org/wiki/Privacy_Policy) |
| Open-Meteo | Automatic: a configured city calls the geocoding API at `geocoding-api.open-meteo.com` when that city is not the last one that failed, and every weather load calls `api.open-meteo.com/v1/forecast`. A blank location and a coordinate pair call only the forecast endpoint. | A city name or coordinates, the requested weather fields, language and time zone. Open-Meteo's logs may contain coordinates and IP addresses. | [Open-Meteo terms and privacy](https://open-meteo.com/en/terms#privacy) |
| GitHub update metadata and release downloads | User action: Settings > Updates checks when the user asks, and installing downloads the chosen ZIP. Metadata comes from `raw.githubusercontent.com/.../nexus-channels/v1/`; the ZIP from `github.com/.../releases/download/`, with redirects allowed only to `objects.githubusercontent.com` and `release-assets.githubusercontent.com` (`windows/scripts/Caelestia-Update.ps1`). | Source IP address, the requested URL, `If-None-Match` and ordinary HTTPS request headers. No GitHub account, token or profile data is sent. | [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) |
| PyPI | Opt-in: the user prepares the colour-scheme runtime. `pip` downloads the locked binary wheels for `materialyoucolor` and `pillow`. | Package names and versions, a Python/pip user agent, the source IP address and pip's own cache traffic. No profile data is sent. | [PyPI privacy help](https://pypi.org/help/#privacy) |
| GitHub (Git) | The same opt-in colour-scheme preparation installs the Caelestia CLI from a pinned commit over `git+https`. | Source IP address and the repository/commit requested. No GitHub account or token is sent. | [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) |
| Microsoft | User action only. If the Visual C++ runtime is missing, the installer prints Microsoft's official download link and leaves the decision to the user. | If the user follows the link, Microsoft sees the request under its own terms. | [Microsoft privacy statement](https://privacy.microsoft.com/privacystatement) |
| YouTube (Google) | Does not happen today. The staged fallback that turned a `xesam:url` YouTube watch URL into `img.youtube.com` artwork (`windows/services/media/PlayersService.qml:146`) cannot fire: the pinned backend's metadata map (`player.cpp:257`) has no `xesam:url`, and artwork comes from the local `trackArtUrl` cache. The row becomes active only if a future backend reports that field. | If it ever fires: the video ID in the thumbnail URL, source IP address and ordinary image-request headers. | [Google privacy policy](https://policies.google.com/privacy) |
| SignPath.io | Only a future release-signing pipeline, which does not exist. The installed shell never contacts SignPath. | The release artifact and its workflow, repository, commit and run metadata. No end-user profile data. | [SignPath privacy policy](https://signpath.io/privacy-policy) |

Media artwork in the shipped shell is local. The backend caches the current
session's thumbnail under the shell cache and reports it as `trackArtUrl`
(`windows/deps/quickshell/src/windows/services/mpris/gsmtc_worker.cpp`), so
showing artwork makes no request. Notification images are accepted only as
theme icon names or as files inside the staged assets directory
(`NotificationsService.qml`); a remote notification image is dropped, not
fetched.

### User-opened destinations

The shell does not fetch these URLs itself. When the user opens one, the URL or
text is handed to the default Windows handler, normally the browser, which makes
the request under the destination's privacy policy. The destination can be any
host because the notification sender or the clipboard supplied it. These actions
are separate from the automatic and opt-in shell requests in the table above.

| User action | What is handed to the handler | Source |
| --- | --- | --- |
| Click a link in an expanded notification | The link from the notification body, as supplied by the app that posted it. The shell does not fetch it and uploads nothing. | `modules/notifications/Notification.qml:483`, `modules/sidebar/Notif.qml:148` |
| Open a single-line HTTP or HTTPS clipboard item | The clipboard text exactly as copied. The shell does not preview or fetch it. | `plugin/src/Caelestia/Windows/Clipboard/windowsclipboardworker.cpp:1197`, `windows/services/clipboard/ClipboardHistory.qml:157` |
| Open release notes or the manual download link on the Updates page | A GitHub release-tag or releases URL that `UpdatesLogic.js` restricts to this repository. | `windows/shell/adapters/modules/nexus/pages/UpdatesPage.qml:36,404,413` |

The shell also opens local files and folders through the registered Windows
handler (`windows/shell/adapters/utils/Paths.qml:129,133`), opens `ms-settings:` pages for network,
Bluetooth, notifications, clipboard and lock-screen settings, and activates an
installed app or a `windowsdefender:` URI when a notification is clicked. Those
targets are on this PC. The clipboard Open action opens images and a temporary
text file through local handlers, and passes `file://` items to the Windows
handler as paths. A `file://server/share/...` item becomes a UNC path, so
opening it contacts that network server, and Windows may send the user's
network credentials to it, as Explorer does for any network share. The shell
does not contact the server unless the user chooses Open on that item.

The upstream Qt Widgets crash reporter and its report-page URL are not compiled
on Windows. The Windows handler writes local dumps and reports and restores
tracked window state. Under the supervisor it does not launch a replacement
process, show a diagnostic window or upload anything. Dumps contain process
memory and cannot be redacted. See
[Crash diagnostics and privacy](SUPPORT-BUNDLE.md#crash-diagnostics-and-privacy)
for the shared cache location, newest-three startup retention and explicit
manual-sharing boundary.

Ways to avoid or limit the requests:

- Configured city: set `services.weatherLocation` to a city name. The shell
  geocodes it with Open-Meteo and requests the forecast from Open-Meteo. It
  contacts neither ipapi.co nor Nominatim. The forecast request still runs on
  every weather load.
- Configured coordinates: set `services.weatherLocation` to
  `latitude,longitude`. The forecast still comes from Open-Meteo, and the first
  load for that pair also asks Nominatim for a place name unless the pair is in
  the local city cache. Only a configured city avoids both ipapi.co and
  Nominatim.
- Blank location: remove `services.weatherLocation`. The shell asks ipapi.co for
  approximate coordinates and a city, shows the returned city directly, and
  requests the forecast from Open-Meteo. It does not contact Nominatim for this
  case. The shell has no separate switch that disables weather network access
  altogether.
- Update checks are user-initiated from Settings > Updates. They do not run on
  startup.
- Colour-scheme runtime preparation is opt-in. Basic use does not download
  packages.
- The Agent usage drawer is inactive without `cpa-agents.json`, and the Agent
  usage panel switch stops its requests live. Hub mode is a separate opt-in,
  except for a stock CLIProxyAPI summary 404, where it is the only source.
  Keepalive runs only when the user chooses it, but its `auth-files` management
  read can use a checked RFC 1918 or Tailscale plain-HTTP endpoint even when
  Detailed usage is off. Run Keepalive only against an endpoint you trust.
- Notification links and clipboard items reach Windows only on an explicit
  click or Open action. Copying text sends nothing. Do not open a link or
  clipboard item whose destination you do not trust.
- Media artwork is loaded from the local cache while a player is active and the
  artwork is visible. The YouTube thumbnail fallback is unreachable at the
  pinned backend.

Signing does not add a network feature to the installed shell. SignPath would see
the release workflow and artifact, not the user's machine.

## Incident handling, rotation and revocation

The code signing certificate would be issued to SignPath Foundation, which is
the publisher named by the signature. The project cannot reissue it directly.
No certificate or token exists today; these are the procedures the pipeline must
follow once one does.

- **Compromised API token.** Revoke it in SignPath, issue a new one, and replace
  it in the protected CI environment. Pause stable publication until the
  replaced token is the only valid submitter. No token is ever committed.
- **Compromised or withdrawn certificate.** Suspend stable publication, report to
  SignPath at support@signpath.io, publish a security advisory through
  [SECURITY.md](../../SECURITY.md), and re-sign the affected release after a new
  certificate is available. Users must treat binaries signed by a revoked
  certificate as untrusted.
- **Compromised signing environment or workflow.** Disable the signing job,
  revoke the token, audit the workflow history, and rebuild from reviewed
  commits. Never re-sign an unchanged artifact to hide a workflow change.
- **Wrong or partial signature.** The release fails verification and is not
  published. The pipeline must never publish an unsigned or partially signed
  artifact as stable.
- **Rotation.** When SignPath replaces its certificate, record the new subject
  and update this page. An RFC 3161 timestamp proves that an older signature was
  created while its certificate was valid, so old releases remain verifiable
  after the certificate expires, unless the certificate was revoked or the chain
  is no longer trusted.

## Current state

- No release is signed. There are no stable releases.
- `v0.1.0-preview.2` and the `v0.2.0-dev.*` pre-releases are the only published
  tags.
- The standalone verifier, its reviewed inventories and the draft artifact
  configuration are checked in but not wired into CI.
- First-party PE files do not yet carry a `VERSIONINFO` resource with product
  name `Caelestia Windows` and the release core version. SignPath's metadata
  restrictions require it, so a signing request would fail closed until the
  build emits it.
- The candidate payload verifier and source-asset coverage still compare
  unsigned hashes with deployed bytes. Signing would change those bytes, so the
  metadata refresh described in [SIGNING-ROADMAP.md](SIGNING-ROADMAP.md) must
  land before a signed stable candidate can pass.
