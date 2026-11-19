# Caelestia capture control protocol v1

The recorder retains the Glazier v1 transport, status and recording controls.
The shell owns interactive capture. The first-party binary rejects `--capture`
and recording requests without an explicit region or fullscreen target.
The first-party binary is `caelestia-capture.exe`. Its managed identity is the
default for every command, including a client invoked with ONLY `--status`;
there is no `--managed` launch/status split. The host window class is
`CaelestiaCaptureHost`, the mutex is `Local\Caelestia.Capture.Instance`.
The shell's legacy `Glazier` service/keybind/IPC aliases remain supported.
External legacy `glazier.exe` overrides retain `GlazierHost` and the old pipe
inside that legacy executable. A separate legacy host is never adopted by class
alone or sent a first-party quit.

## CLI

Exactly one command is accepted:

| Command | Action |
| --- | --- |
| `--record --region x,y,w,h` | Record a physical desktop region. Add `--no-ui` to let the shell own the border and controls. |
| `--record --fullscreen` | Record the complete monitor containing the pointer, without a picker. |
| `--stop` | Stop and finalize an active recording. Idle is a no-op. Never starts a host or recording. |
| `--pause` | Pause a recording. Rejected outside `recording`. |
| `--resume` | Resume a paused recording. Rejected outside `paused`. |
| `--discard` | Stop without publishing the recording. |
| `--audio` | Change `--system-sound` or `--mic` on an active recording. |
| `--status` | Read the live host snapshot. Never starts a host. |

Recording options are `--system-sound on|off` and `--mic on|off`. Omitted
options use Glazier's saved audio preferences. Overrides apply to this recording
without changing saved preferences; the bar's toggles still work normally.
`--fullscreen` uses physical monitor bounds and the existing even-pixel H.264 crop.

Two launch options configure a newly started host. They are not commands and may
appear before or after one:

| Option | Action |
| --- | --- |
| `--theme-file <path>` | Use this theme-token JSON instead of `config.toml`'s `theme_file`. It is re-read when recording starts and survives **Reload settings**. |
| `--no-hotkeys` | Accepted for legacy callers; the helper no longer registers hotkeys. |

Launch options only affect the process that creates the host. A command forwarded
to an already running host uses that host's current options, and no second
instance or window is created.

`--record` starts the tray host if necessary; otherwise it forwards
to it. Other commands only connect. Command clients print one JSON response to
stdout and exit 0 for success or 1 for failure. A newly started host stays running
and does not print a startup response. Launch it detached with stdin/stdout/stderr
redirected to NUL. Use `--status` to observe startup. Starting an old Glazier without
v1 support is not supported; upgrade the app first.

## Transport and security

The local byte-mode named pipe is
`\\.\pipe\Caelestia.Capture.Control.v1.<current-user-SID>.<Windows-session-id>`.
Its protected DACL grants access only to that user SID, it rejects remote clients,
and the first-instance flag prevents silently joining another server's pipe.
Client handles are non-inheritable and use anonymous security QoS so a server
cannot impersonate them. Windows administrators with debug/ownership privileges
remain outside this boundary, as with other current-user resources.

This is simpler than a state-file protocol: there is no stale running flag after
a crash, atomic file replacement/recovery, or second command channel to secure.
The pipe thread only transports requests; all recorder access runs on the host's
UI thread. Slow/invalid clients are bounded and never block that UI thread.

Send one UTF-8 JSON object followed by LF, then read one response followed by LF.
After consuming the response send a single LF acknowledgement, then close.
The server waits at most 3 seconds for the acknowledgement before disconnecting;
this avoids discarding unread response data. One connection handles one command.
Requests/responses are limited to 64 KiB. A request must arrive within 3 seconds;
UI dispatch waits at most 10 seconds. Clients should allow 12 seconds for a
response and retry a busy pipe briefly, not retry recording commands blindly.
There are no unsolicited pushes: poll status (Caelestia uses 500 ms).

```json
{"version":1,"command":"record","fullscreen":true,"system_sound":true,"mic":false}
```

`stop`, `pause`, `resume`, `discard` and `status` use just `version` and
`command`. `audio` accepts `system_sound` and `mic`. `record` requires exactly
one of `fullscreen: true` and `region: {x,y,w,h}`; `ui: false` hides native controls.
Unknown versions and malformed commands do not execute. Non-idle record requests are
rejected rather than toggled or queued to begin later.

## Response

```json
{
  "version": 1,
  "ok": true,
  "host_id": "opaque-host-instance-id",
  "state": "recording",
  "elapsed_ms": 1250,
  "system_sound": true,
  "mic": false,
  "output_directory": "C:\\CaptureFixtures\\Screen Recordings",
  "event_sequence": 1,
  "events": [{"sequence":1,"type":"started"}]
}
```

`host_id` changes on host restart. `elapsed_ms` comes from Glazier's recording
clock, excludes pauses, and freezes during finalization. `output_directory`
respects `recording_directory`, including environment expansion and the Windows
Videos known folder. It does not imply a completed output exists.

The states are `idle`, `ready`, `recording`, `paused`, `finalizing`.
`ready` covers encoder startup before its `started` event. Region selection
happens in the shell before it sends a recording request. Pause/resume move
between recording and paused. Discard emits cancelled, never finished.

Events are a bounded journal of the last 32 recorder events, oldest first:
`started`, `paused`, `resumed`, `finished`, `cancelled`, `error`. Sequence numbers
increase within a host instance. Track `(host_id, sequence)` to deduplicate;
the snapshot remains authoritative if a poll misses more than 32 events.
Errors carry `message` and can be nonfatal, for example an audio warning while
video continues. CLI command validation errors also enter this journal.

Only `finished` includes `output_path`. It is emitted after Media Foundation has
finalized the MP4 and Glazier has published its final filename. Never infer a
finished file from stop acknowledgement, process exit, directory contents while
recording, or `finalizing`. Unpublished files have `.glazier-` names.

A failure response has `ok:false` and `error`. Rejected commands include the
unchanged current snapshot; connection/parsing/version errors may have no
snapshot. An unavailable host returns a CLI error, not a fabricated idle state.
Recorder state/events include actions from the bar and tray, not only
public commands. Screenshot capture does not change recorder state/events.

## Automated verification

`cargo test --no-run` builds the tests. Run the resulting `target\debug\deps\glazier-*.exe`
from a disposable temporary working directory. The pipe round-trip test uses a
message-only window and a process-specific test pipe, never the installed host.
Regular tests do not capture screens or open audio devices. The remaining
native tests are ignored by default, with reasons in their test attributes.
