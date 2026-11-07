# Capture host lifetime and reload

Capture is maintained in `windows/capture` and built as
`caelestia-capture.exe`, with origin and Cargo.lock identity recorded in the
source lock. Legacy protocol, configuration and keybind aliases remain
compatible; the source migration preserves licensing and origin notices.

## Ownership and interruption policy

`CaptureHostRegistry` lives for the native shell process, outside the reloadable
QML graph. Each `CaptureHost` facade acquires a monotonically increasing writer
lease. Destroying a retired facade releases only its own lease and never closes
a process. Observations survive even if there is temporarily no QML facade.

The registry retains an open process handle, PID, creation time, canonical full
image path, window identity and protocol host ID. Observing a handle is distinct
from owning the host. Foreign identities get an exit watch, not ownership.
Notifiers are disabled and deleted before handle release or replacement,
including startup, exit and registry destruction. Window class alone never
authorizes a close or a command. The legacy class-only `WindowsProcess` close
methods fail closed, without waiting. A foreign/inaccessible process is never
closed, killed or silently replaced.

Native launch retains the `CreateProcessW` creation handle, including for a
startup that exits immediately. It inherits no handles or console and uses the
executable's directory. A forwarding client is not the host. `launchedHost`
freshness belongs only to the launching lease and a verified matching host PID,
not to a later QML generation that inherits the same host.

The visible states are `Absent`, `Probing`, `Starting`, `Owned`, `Foreign`,
`Closing`, `CloseFailed` and `Exited`. `snapshot.checking` indicates a pending
asynchronous health/policy check. `snapshot.error` reports refusal, uncertainty
or failure; accepting an asynchronous request never means it completed.

Soft reload hands the process-global registry to the next generation without
closing, launching or adopting a different process. Selecting, recording,
paused, finalizing, Foreign, inaccessible, unhealthy and Starting states all
permit reload. Only a successfully posted close whose exit is still unresolved
refuses handoff, including after its deadline. Failed posting does not create
that gate. A new facade can acquire the current writer lease before its startup
timer runs, so an immediate second reload works too.
`shell.restart` still immediately returns the retired generation string.
`Start-Caelestia.ps1` still waits for a different rendered generation; a refused
handoff cannot satisfy that check. The generation string is an acknowledgement,
not a success claim. Returning an error string instead would incorrectly satisfy
the existing readiness comparison; errors remain in `shell.captureHostState`.

Explicit `stopHost`/`restartHost` and shell quit instead check fresh status and
refuse selecting, ready, recording, paused and finalizing states. Protocol v1
does not describe the screenshot editor, so any other visible window belonging
to the verified host conservatively prevents close too. Shell quit waits for
observed host exit; refusal/failure leaves the shell alive. With no owned identity,
quit leaves the Foreign/inaccessible host alone, cancels discovery and exits the
shell. `shell.quit` returns a Boolean acceptance, not exit success. A pending
check/close refusal always has an error. Native quit completion is lease-bound
and distinct from reload errors, so a refused concurrent reload cannot cancel
an accepted quit. Repeated quit does not cancel it either. A close deadline
finishes the quit request as failed; a later host exit does not unexpectedly
quit the shell.

Close uses `PostMessageW(WM_CLOSE)` followed by `QWinEventNotifier`, not a
GUI-thread process wait. Failed posting or the 2-second deadline retains
identity, ownership and exit observation. No adoption, forwarding or duplicate
launch is allowed while a close is unresolved. A late exit transitions to
`Exited`; only then may an explicitly requested host restart launch again.
Startup has a 20-second observation window, longer than the status client's
16-second bound. Timeout stops new automatic startup polls but does not discard
a healthy response already in flight (at most another 16 seconds). A subsequent
explicit command, close or ensure can perform bounded re-verification of the
same retained identity after timeout, status failure or restored access.
Commands that request re-verification return false and are not queued: retry
after `Owned`. No uncertain state authorizes duplicate launch.

An owned host's nonzero exit code can recover automatically after 200 ms, at
most three recovery launches in addition to the initial cold launch. Code zero
(including tray Quit) and unknown exit codes stay stopped. Foreign exit never
auto-launches anything. Reload does not reset the budget. An explicit user
capture or a safe explicit host restart can re-arm it. A host verified for
60 seconds before exit resets the crash budget; failed health verification
invalidates that stable window. This is a runtime window, not periodic health
certification. Startup uncertainty never licenses another launch, even when
process access could not be retained.

## Callers and payload changes

The normal `Start-Caelestia.ps1 -Command Restart` path is an in-process soft
reload, not an executable replacement. Screenshot/picker/record entry points
and `CAELESTIA_GLAZIER_EXE` compatibility remain in place. Recorder Start delegates
native ownership/forwarding rather than writing `ownedHost` or `launchedHost`.

Installation/update/rollback uses full Quit and `Stop-CaelestiaHosts` through
`Caelestia-InstallCommon.ps1`, not soft reload. The desktop supervisor also has
its own full-process quit/recovery path. Those scripts are unchanged here.
A graph requesting a different executable while an identity is retained gets
`Foreign`, not adoption; exit cannot auto-relaunch the retired executable. It
can still reload or quit without closing that old identity. If no close was
posted, reverting the path permits re-verifying the retained identity; after
observed exit, an explicit capture may cold-start the selected payload.
Package/full-stop acceptance must cover the actual installer and supervisor,
including their existing force-stop paths and timeout budgets. This patch
does not claim to make those independent paths recording-safe.

## Focused regression command

From an isolated native Windows checkout, using prepared Qt 6.11.2, LLVM 20.1.8,
VS 2022 VC 14.44.35207 and SDK 10.0.26100.0:

```powershell
./windows/scripts/Test-CaptureHostLifecycle.ps1 -BuildRoot D:/Caelestia/validation-erm631-restart-20261106
```

The output directory must be absent or carry this checkout's ownership marker.
The runner builds with parallelism 2, runs offscreen, fails nonzero/empty/skipped
native runs, and records source heads, dirty state, tools, counts and fixture
binary hashes and source diff hash in a new `logs/<run>/receipt.json` for each
invocation. Failed logs are retained too. CTest bounds the fixture run to
90 seconds and every hidden child self-exits within 30 seconds. All fixture
environments are offscreen before startup. No `qml.exe` help/version probes
are used. Tools are read-only; there is no install,
desktop manipulation, actual Glazier launch, capture or recording.

The Qt fixture compiles the real production registry/facade. Its fake-operations
cases cover posting failure, access denial/loss, foreign/reused identity,
unhealthy/mismatched host status, every active phase, screenshot-window refusal,
deadline then late exit, closing-generation overlap, startup uncertainty,
bounded recovery, clean exit, stable-window reset, payload replacement refusal,
notifier/handle replacement ordering and retired lease destruction.
It creates four actual `QQmlEngine` generations loading both production service
files byte-for-byte with dependency fakes, keeping one simulated recording
identity and checking Recorder forwarding freshness. Additional QML cases
execute the actual shell quit/restart/state IPC function bodies extracted into
a dependency-faked root across Owned, Foreign, Starting, CloseFailed, access
denial, failed posting, recording and late exit. They observe `QQmlEngine::quit`,
not application/desktop termination, and exercise reload before the startup
timer. Two cases use an owned
hidden Win32 child, a unique nonproduction window class, actual process handles,
`CreateProcessW`, status clients, `PostMessageW` and exit notification. The delayed
close case verifies event-loop heartbeats while the process stays alive past
its deadline. The child never shows a window or calls foreground/input/capture
APIs.

The focused suite contains 44 Qt result rows, including init/cleanup,
with zero skips, plus 51 Node assertions against actual Recorder JavaScript.
The Node failure-before command reads the exact old source without checking it
out or changing the worktree:

```powershell
node windows/tests/GlazierRecorderLogic.test.js 2bda261d5c467a5e4c71b85fdfd12aff7717a2a7
```

It must fail the forwarded-host ownership/freshness assertion. The same command
without a revision tests the working source and must pass.

Production registration can also be compiled without staging/installing:

```powershell
cmake -S . -B <exclusive-output>/plugin -G Ninja `
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl `
  -DCMAKE_LINKER_TYPE=MSVC -DCMAKE_PREFIX_PATH=<QtPrefix> `
  -DCAELESTIA_WINDOWS_TESTS=ON -DCAELESTIA_PORTABLE_UI=ON
cmake --build <exclusive-output>/plugin --target caelestia-windowsplugin --parallel 2
```

## Evidence limits and retained acceptance

Fixture evidence is not installed-shell, GPU, WGC, SDR/HDR, audio, tray, hotkey,
finalized-file or recording-across-reload evidence. The offscreen fixture does
not run Quickshell's full graph/window reload machinery. Its four generations
currently emit Qt's `Empty filename passed to function` warning during fixture
setup; there are no QML parse failures in the passing run.

The unmodified v1 protocol has no atomic idle-and-close transaction and does not
authenticate its same-user pipe beyond its existing boundary. This phase checks
fresh idle status, visible host windows and process identity immediately before
posting close, but does not claim to eliminate a simultaneous external
tray/control action in that interval. Such a stronger guarantee requires the
coordinated helper/protocol phase, not fabricated certainty from a model test.

Retain independent final review, exact shell/plugin/backend candidate
integration, package/full-stop checks, and authorized disposable physical
recording across repeated reloads as external acceptance. No task is Done from
these component results alone.

Implementation baseline: shell `2bda261d5c467a5e4c71b85fdfd12aff7717a2a7`
(tree equal to merged main `0e737ee65c322bb26083d682b78313001b7050a4`),
backend `e6039b2b9cbb35b97473bda4dcc3f12789ae7f0c`,
Glazier `37f795041cbbb32ed46cba103f3f000a3a99ac13`,
M3Shapes `32ad9ce328bb77ed349b40a3be10ee9ea610b8ab`.
