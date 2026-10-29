# Glazier recorder adapter

Requires Glazier with control protocol v1. The adapter replaces the limited
ffmpeg/gdigrab recorder rather than falling back: a fallback would silently lose
region, audio, pause and single-monitor semantics. Missing/incompatible Glazier
is named in the original Record card and its start menu is disabled.

The executable is resolved from `%LOCALAPPDATA%\Programs\Glazier\glazier.exe`,
then PATH. `CAELESTIA_GLAZIER_EXE` is an explicit override, including for tests.
Install a compatible version before enabling this integration. A stopped v1 host
reports "not running" until Start launches it; this does not disable cold start. A missing Glazier is probed again every 30 s.

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

Start uses `Quickshell.execDetached`, whose Windows #81 implementation redirects
stdio to NUL and disowns inherited handles. Short-lived status/pause/resume/stop
clients use `Process`. No recorder is killed to stop a recording.

Status is polled even with the card closed, every 500 ms while the card is open or
something is happening and every 5 s while idle. Glazier owns the elapsed
clock and finalization. The last 32 sequenced events are deduplicated per host.
The first response from a host is a baseline: its older events are not replayed
(no stale error), though its finished files are noted.
Only a finalized `finished.output_path` updates `lastFile`. A lost host clears
stale recording indicators and reports the failure. Live-off and smoke profiles
neither probe nor launch Glazier.

Delete only removes files Glazier reported in a `finished` event; the list
otherwise shows every `.mp4` in the output folder. The newest 500 such paths are
kept in `<profile>\state\caelestia\recordings.json` (missing or corrupt files are
ignored), and Delete is disabled for any other file. Recordings Glazier made
before this was introduced stay listed but cannot be deleted from the card; use
the folder button. Output paths are never logged or displayed.

The original Record card, RecordingList and delete confirmation are staged.
Small `Windows:` hooks expose availability/status and name filters; the Windows
Paths adapter binds the recordings directory to Glazier's configured output.
Player/folder actions use Windows default applications, and delete converts
native paths to local-file URLs rather than treating drive letters as schemes.
`[!.]*.mp4` includes custom finalized names but excludes unpublished dot files.
The portable build now includes the existing FileSystemModel without Linux appdb.
No Glazier theme or screenshot launch-action changes are included.

## Verification

```powershell
windows/scripts/Build-Prototype.ps1 -BuildRoot C:\b-grec <toolchain arguments>
windows/scripts/Test-GlazierRecorder.ps1 -BuildRoot C:\b-grec -QtPrefix <Qt prefix>
```

The fixture compiles an isolated stub executable and stages the actual adapter,
Record card and recordings list under a temporary directory. Qt runs offscreen.
It checks start, pause, resume, finalizing/finished, sound/region flags, unpublished
file exclusion, file-URL conversion/deletion, error/missing/incompatible
states, cancellation, host loss, live-off/smoke gates, and a
tray-initiated recording reflected in the original card. It does not run the
installed Glazier, capture a screen, use a microphone, or operate the desktop.

The graphical delete confirmation is not covered by this fixture. A separate
rapid open/delete/restart experiment hit a Qt Quick access violation in the
software/offscreen renderer; waiting for the modal to settle avoided it. No
speculative production workaround is included. Check native delete/modal
teardown and rapid restart with the default D3D renderer before acceptance.

Still needed, by the dedicated desktop QA agent with explicit live-test authority:
install a compatible Glazier; verify cold/warm detached launch, fullscreen on
each monitor, region selection/cancel, silent/system-sound modes, pause/resume,
stop and playable finalized MP4, list/open/reveal/delete, tray/hotkey reflection,
failure recovery, and Glazier survival when the shell exits. Do not merge until
the requested review/acceptance process is satisfied.
