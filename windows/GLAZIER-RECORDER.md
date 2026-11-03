# Glazier recorder adapter

Glazier ships with Caelestia. The adapter uses the bundled executable, resolving
it first from the running payload (`<payload>\glazier.exe`, the sibling of
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

At startup the shell identifies the running host by the image path of its
`GlazierHost` window. A host from this payload is adopted. A standalone host, or
one left by an older payload, is asked to exit through its own `WM_CLOSE` and is
then replaced by the bundled executable; its install and HKCU Run entry are not
touched. Shell quit/restart stops the owned host, and the installer stops any
`glazier.exe` under `<prefix>\versions\` before a payload swap, retirement or
uninstall, so an old payload cannot stay locked.

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

Start uses `Quickshell.execDetached`, whose Windows #81 implementation redirects
stdio to NUL and disowns inherited handles. Short-lived status/pause/resume/stop
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

Path-identity hardening (#109 item 4): ownership is by the normalised
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

```powershell
windows/scripts/Build-Prototype.ps1 -BuildRoot C:\b-grec <toolchain arguments>
windows/scripts/Test-GlazierRecorder.ps1 -BuildRoot C:\b-grec -QtPrefix <Qt prefix>
windows/scripts/Test-Glazier.ps1 -BuildRoot C:\b-grec -QtPrefix <Qt prefix>
```

The recorder fixture compiles an isolated stub executable and stages the actual
adapter, Record card and recordings list under a temporary directory. Qt runs
offscreen. It checks bundled resolution without an override, start, pause,
resume, finalizing/finished, sound/region flags, unpublished
file exclusion, file-URL conversion/deletion, error/missing/incompatible
states, cancellation, host loss, live-off/smoke gates, and a
tray-initiated recording reflected in the original card. It preserves the staged
profile-directory pragmas and checks the actual profile-local store for
missing/corrupt recovery, the 500-entry cap and ownership across a second shell
process, including suppression of an old host error on restart. The original
list's Delete state is checked for owned, unreported and cap-evicted files and
when ownership changes. Separate cold-start-error and real 15 s timeout scenarios
check that subsequent valid idle responses retain the failure. It does not run the
installed Glazier, capture a screen, use a microphone, or operate the desktop.

`Test-Glazier.ps1` stages a disposable payload (`<root>\payload\stage` with
`glazier.exe` beside it) and checks bundled-first resolution, the explicit
config fallback, removal of the old installed default, the exact
`--no-hotkeys --theme-file` launch contract, one owner per hotkey chord, and
dismissal that waits for the real panel `visibleChanged` signal. The timeout
route asserts that no capture launches and that the user sees "Glazier is not
ready".

For portable logic-only regression checks, run
`node windows/tests/GlazierRecorderLogic.test.js` from a disposable working
directory (use the script's absolute path). It executes the adapter's JavaScript
with in-memory process/store doubles, not Quickshell, real persistence or UI.

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
