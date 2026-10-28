# Grok Bot on Windows

This ports the avatar, faces, animation, attention ordering and roster from
`overlay/quickshell/` at `621dccaf035e1a1b9bf2f808c18c2aa0d26e7db6` in
`KldsSeeGhosts/caelestia-hypr-dotfiles`. It is disabled by default.

The Linux `omabot-watch.py` reads Grok Bot's local
`~/.config/Grok Bot/sand-client-persistence` blob store. It obtains roster,
unread counts, last message previews and activity from the roster, derives
working state from transcript replicas, and decodes local avatar images. It
checks a Linux process and uses Hyprland to focus or launch the app. It is not
an HTTP service. Grok Bot for Windows uses the same persistence format under
`%APPDATA%\Grok Bot\sand-client-persistence`.

## Enable the Windows producer

Create `%LOCALAPPDATA%\caelestia-windows\config\grokbot.json`:

```json
{"enabled": true}
```

The shell starts an attached Python helper using the scheme runtime's Python.
If that runtime is unavailable, the roster stays offline. It opens only the
`client-meta.account-slot`, `roster.last-roster`, and the selected bots'
`transcript.replicas.<bot-id>` blobs. The active account is preferred; if the
slot is present but its roster is missing, the helper does not switch accounts.
When the slot is absent it uses the most recently modified roster, as on Linux.
It caches projected values for unchanged blobs and uses transcript entry kinds,
roles and timestamps to infer working status for 15 minutes. Transcript bodies
never enter its cache or snapshot. Previews come only from the roster and are
limited to 160 characters. Avatar blobs, credentials and secret stores are not
opened. The helper makes no network requests.

The helper atomically replaces `<profile>\runtime\grokbot-snapshot.json` every
1.5 seconds as a heartbeat. The path can be overridden with an absolute local
`snapshotPath` in `grokbot.json`; the helper will replace that file. The
snapshot contains names, titles and message previews, so protect the profile
and any overridden path with appropriate file permissions. The last snapshot
remains on disk after exit; it becomes stale after 60 seconds. The helper is an
attached Quickshell `Process`, owned by the Windows kill-on-close job, and stops
when disabled or the shell exits. It never logs the persistence or snapshot.

With no enabled configuration, no helper, snapshot polling, bar entry or new
window is created. The configuration file probe remains active. Missing,
malformed, inaccessible or oversized source files leave the roster offline.
Each persistence blob read is bounded to 16 MiB.

## Snapshot contract

For an independently supplied snapshot, use `"source": "snapshot"` along with
an absolute local `snapshotPath`. The same attached helper performs a bounded
read, but does not write the file or read Grok Bot persistence. Every snapshot
read is capped at 256 KiB before it reaches QML. It has `generated_ts` in Unix
seconds, `app.running`, `counts` (`bots`, `awaiting`, `working`, `unread`) and
`bots`. Bot fields are `name`, `title`, `description`, `shape`, six-digit
`hex`, `unread`, `awaiting`, `working`, `last_text` and `last_activity_ts`
in Unix seconds. Invalid types or values clear the state; unknown fields are
discarded, strings are bounded and at most 32 bots are retained. Counts are
recomputed from those bots. A producer must atomically refresh the timestamp at
least every 60 seconds.

The Windows producer does not inspect the app process, so `app.running` is
false rather than a guessed running state. Custom image avatars, demo toggle,
app focus and launch are unavailable; drawn shapes, expressions, badges,
roster text and popout motion are retained.

`windows/scripts/Test-GrokBot.ps1` exercises the staged production graph with
synthetic snapshots and persistence in temporary profiles, including helper
lifetime after simulated shell death. `test_grokbot_watch.py` covers the
producer's input allowlist, cache, working heuristic and bounds. Real Windows
Grok Bot data, native popout positioning, multi-monitor DPI, hover behaviour
and motion still need live desktop QA.
