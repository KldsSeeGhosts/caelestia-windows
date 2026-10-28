# Grok Bot on Windows

This ports the avatar, faces, animation, attention ordering and roster from
`overlay/quickshell/` at `621dccaf035e1a1b9bf2f808c18c2aa0d26e7db6` in
`KldsSeeGhosts/caelestia-hypr-dotfiles`. It is disabled by default.

The Linux `omabot-watch.py` reads Grok Bot's local
`~/.config/Grok Bot/sand-client-persistence` blob store. It obtains roster,
unread counts, last message previews and activity from the roster, derives
working state from transcript replicas, and decodes local avatar images. It
checks a Linux process and uses Hyprland to focus or launch the app. It is not
an HTTP service. No verified Windows producer or portable path is supplied by
that project.

## Snapshot boundary

An independent, explicitly configured producer may publish the watcher's JSON
snapshot to a local file. Put this file in the shell profile's `config` folder
as `grokbot.json`, substituting an absolute local Windows file path:

```json
{"enabled": true, "snapshotPath": "C:\\path\\to\\grokbot-snapshot.json"}
```

The snapshot has `generated_ts` in Unix seconds, `app.running`, `counts`
(`bots`, `awaiting`, `working`, `unread`) and a `bots` array as produced by
the Linux watcher. A bot can include `name`, `title`, `description`, `shape`,
six-digit `hex`, `unread`, `awaiting`, `working`, `last_text` and
`last_activity_ts` in Unix seconds. The producer must update `generated_ts`
at least every 60 seconds and publish atomically. Missing, malformed, stale or
future-dated data is offline, and old rows are cleared. The adapter reads the
configured file every 1.5 seconds and does not start a producer. With no valid
config it neither polls the snapshot nor adds the bar item or opens a window.
There is no network access or credential handling in this adapter.

The snapshot can contain sensitive names and message previews. Keep it and
its producer under the user's control outside the repository and protect
their file permissions. No data is logged or cached by this port. Custom
avatar images, demo toggle, app focus and launch are intentionally unavailable:
the Linux implementation has no safe Windows equivalents yet. The remaining
drawn shapes, expressions, badges, roster text and popout motion are retained.

`windows/scripts/Test-GrokBot.ps1` stages the production graph and exercises
synthetic configured, unconfigured and offline profiles with Qt offscreen.
Real producer compatibility, native popout positioning, multi-monitor DPI,
hover behaviour and motion still need live desktop QA.
