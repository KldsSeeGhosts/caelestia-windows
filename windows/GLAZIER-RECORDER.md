# Glazier recorder adapter

Caelestia Capture ships with Caelestia, maintained from the recorded Glazier
origin. The adapter uses the bundled executable, resolving
it first from the running payload (`<payload>\caelestia-capture.exe`, the sibling of
`qs.exe`) and only then from an explicit absolute path in the profile's
`config\glazier.json`. `CAELESTIA_GLAZIER_EXE` is an explicit test and
development override. There is no `%LOCALAPPDATA%\Programs\Glazier` or PATH
fallback, and the tool is never downloaded during install or update.

The adapter replaces the limited ffmpeg/gdigrab recorder rather than falling
back: a fallback would silently lose region, audio, pause and single-monitor
semantics. A missing or incompatible bundled Glazier is named in the original
Record card and its start menu is disabled. A stopped v1 host reports "Glazier
stopped" until Start launches it; this does not disable cold start. A missing
Glazier is re-checked every 30 s by a native path lookup, with no helper process.

The shell starts Glazier in its tray with `--no-hotkeys --theme-file
<profile>\state\caelestia\theme-tokens.json`; the pinned revision supports both
options. The shell owns `PrintScreen` / `Win+Shift+S` for screenshots and
`Win+Shift+R` for recording (see `windows/docs/KEYBINDS.md`).

At startup the shell verifies the host's image, process creation time, window
identity and v1 status, retaining its process handle outside the QML graph.
A matching host can be adopted. A standalone host or one from an older payload
is observed without ownership, never closed or silently replaced. Shell reload
preserves the registry and any recording. Only a posted unresolved close blocks
reload. Quit leaves an unowned host alone; for an owned host it first requires
fresh idle status and no visible capture windows, then waits asynchronously for
exit. Refusal or timeout leaves the shell alive with an error. The installer
separately stops any
`caelestia-capture.exe` or legacy `glazier.exe` under `<prefix>\versions\` before a payload swap, retirement or
uninstall. Those full-stop and supervisor paths retain separate acceptance;
the lifecycle fixture does not establish their recording safety. Clean tray
Quit stays stopped until an explicit capture. Crashes allow three recovery
launches beyond cold start, reset after a 60-second verified runtime window.
See [capture-host-lifecycle.md](docs/decisions/capture-host-lifecycle.md) for
retry, timeout, ownership and protocol-v1 limits.

Screenshot dismissal collapses the Windows click-toggle tray as well as the
panels (`autoCollapse` is false there) and waits for the tray's height animation
to finish before launching the capture. As with the panels, a timeout reports
"not ready" and never captures over visible shell UI.

The upstream Recorder contract remains `running`, `paused`, `elapsed`, `refCount`,
`start(extraArgs)`, `stop()`, `togglePause()`. Upstream modes map as follows:

| Upstream flags | Glazier |
| --- | --- |
| none | Full current monitor, no audio |
| `-r` | Region picker, no audio |
| `-s` | Full current monitor, system sound |
| `-sr` | Region picker, system sound |

The microphone is explicitly off for these four modes. Glazier's own controls
can change either audio source. A selected region begins recording automatically;
Glazier's tray/hotkey review behavior is unchanged. Full current monitor means the
monitor containing the pointer, with Glazier's existing even-pixel H.264 crop.

With `windows.capture.ui: "shell"`, launcher Record and the record shortcut use
the QML region picker. The default remains `"classic"`, and a legacy `glazier.exe`
override always keeps the classic flow. The helper receives `--region x,y,w,h`
and `--no-ui`, equivalent to protocol-v1 `record.region` and `record.ui: false`.
The region uses physical virtual-desktop pixels. Only local monitor offsets
scale by DPR, and the helper crops the region to even dimensions.

The shell draws an excluded border and controls. Pause/resume, Stop, Mic,
Sound and Discard use the helper's control protocol. Additive v1 `audio` and
`discard` commands expose the existing worker actions. Neither command starts
a host. Status includes `region` and `ui` so a reload can restore the controls.
The helper still owns elapsed time, the journal, output files and recovery.

Start delegates to the native identity registry. Cold launch retains the
`CreateProcessW` handle without inherited handles or a console. A forwarding
client never claims host ownership or launched-host journal freshness.
Short-lived status/pause/resume/stop
clients use `Process`. No recorder is killed to stop a recording.

Status is polled even with the card closed, every 1 s while the card is open or
something is happening, every 15 s while idle and every 5 s after a connection
failure. Glazier owns the elapsed
clock and finalization. The last 32 sequenced events are deduplicated per host.
The shell's initial host response is a baseline: its older events are not
replayed (no stale error), though its finished files are noted. Start waits for
that initial observation, or a compatible stopped-host response, because v1
events have no timestamp to distinguish an older failure from a new attempt.
Once observed, a stopped or replaced host's first-response errors are fresh,
even without a pending Start. So are the first-response errors of a host this
shell session created itself (`Glazier.launchedHost`). Forwarding a screenshot
or recording command to a host that is already running does not create that
host, and only an adopted, pre-existing host is baselined. Recording errors and the 15 s Start timeout
survive valid idle polls and connection recovery; a new Start, `started` event
or confirmed recording clears them. Transient connection errors clear on a
valid host response.
Only a finalized `finished.output_path` updates `lastFile`. A lost host clears
stale recording indicators and reports the failure. Live-off and smoke profiles
neither probe nor launch Glazier.

Delete only removes files Glazier reported in a `finished` event; the list
otherwise shows every `.mp4` in the output folder. The newest 500 such paths are
kept in `<profile>\state\caelestia\recordings.json` (missing or corrupt files are
ignored), and Delete is disabled for any other file. Recordings Glazier made
before this was introduced stay listed but cannot be deleted from the card; use
the folder button. Output paths are never logged or displayed.

Path-identity hardening ( item 4): ownership is by the normalised
(lowercased) path string, not by OS file identity (volume/file ID), so a file
replaced at the same path, reached through a retargeted parent/junction, or
differing only by case in a directory with Windows per-directory case
sensitivity enabled is treated as the recording Glazier reported. For a local
single-user desktop shell this is deferred with no behaviour change.

The original Record card, RecordingList and delete confirmation are staged.
The card's full-width status wraps to at most two lines at the utilities width,
so the availability and failure messages are not cut off.
Small `Windows:` hooks expose availability/status and name filters; the Windows
Paths adapter binds the recordings directory to Glazier's configured output.
Player/folder actions use Windows default applications, and delete converts
native paths to local-file URLs rather than treating drive letters as schemes.
`[!.]*.mp4` includes custom finalized names but excludes unpublished dot files.
The portable build now includes the existing FileSystemModel without Linux appdb.
The shell's Glazier adapter owns launch, hotkeys and screenshot dismissal.

## Verification

Build with the pinned bundled Glazier using [NATIVE-BUILD.md](NATIVE-BUILD.md).
The public production smoke checks loading with recording and capture
disabled; it does not capture a screen or establish live recorder behavior.

With explicit live-test authority and synthetic content, verify cold/warm
launch, fullscreen on each monitor, region selection/cancel, silent/system-sound
modes, pause/resume, stop and playable finalized MP4, list/open/reveal/delete,
tray/hotkey reflection, failure recovery and owned-host shutdown. Include
delete/modal teardown and rapid restart with the default D3D renderer.
Keep recordings and screenshots outside the checkout and exclude personal data.
