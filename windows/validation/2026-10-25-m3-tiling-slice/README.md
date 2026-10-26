# M3 tiling opt-in slice, 2026-10-25

This archive records M3-2 stages 4/5 groundwork plus the M3-3
fitting-failure explanation as a bounded slice on branch `t3/m3-tiling-slice`:
a pure tiling service with an `off|observe|interactive` opt-in policy, a
feature-detected wrapper for the backend `Tiling` controller, and toast
decisions on Caelestia's original toast surface.

**No tiler was enabled and no native tiling controller was constructed in any
recorded run.** Native runs were limited to `-TilingMode Disabled`; Observe
and Interactive belong to the orchestrator's live runs on a prepared desktop
and are deliberately not reachable from this harness. No window was moved, no
tiler mutex was taken, no shortcut was sent and no desktop was switched.

## Sources and runtime

- Implementation commit `2dd2794f6e25b31263010388b725942effed106a`, clean
  during the recorded runs (`sourceDirty=false` in both matrices). The
  evidence commit that adds this directory is later and changes no runtime
  source.
- Backend unchanged at `1401042969e4b7ab3cfb314fc76945ab081db3de`; no
  gitlink, `windows/sources.lock.json` or submodule edit is part of this
  slice. The fork branch `windows/m3-windows-stack`
  (`cd170acf422366937ac87092a06c6ee6348dcbcb`) that adds `included`,
  `lastError`, `managedCount`, `failedCount`, `enableRefused` and
  `windowTilingFailed` was read via `git -C windows/deps/quickshell show
  FETCH_HEAD:...` only; it was never checked out or built.
- Windows 11 Pro `10.0.26300`, Qt `6.11.2`, existing shared build
  `D:\AiStack\caelestia-windows\windows\.local\build`. QML/PowerShell-only
  changes; no rebuild was performed.
- Primary monitor at native 150%; secondary at native 175%.

## Delivered behavior

The pure [TilingService](../../services/tiling/TilingService.qml) imports no
Quickshell module and constructs nothing. `configure()` validates
`CAELESTIA_WINDOWS_TILING=off|observe|interactive` (anything else is `off`
with a warning) and parses `CAELESTIA_WINDOWS_TILING_INCLUDED` /
`CAELESTIA_WINDOWS_TILING_EXCLUDED` as semicolon-separated wildcard lists
(trimmed, empty entries dropped). `off` never requests the native wrapper
(`nativeRequested` false); a wrongly attached backend is neither given
options nor asked to enable. `observe` applies options and keeps `enabled`
false. `interactive` requests enabling only with a non-empty allowlist on a
backend that supports `included`; without either it refuses with a status
reason and never enables. Smoke forces interactive down to observe
(requested mode preserved for honest output). Wrapper load failures surface
as `refused` with the component error.

The [wrapper](../../services/tiling/NativeTilingBackend.qml) imports
`Quickshell.Windows` and feature-detects every post-pin member with `typeof`:
on the pinned backend `supportsIncluded=false` (interactive therefore always
refuses), telemetry reports `0`/empty and the signal forwarding stays
disconnected. `requestEnable()` is the only path that can set
`Tiling.enabled`. The [facade](../../services/tiling/Tiling.qml) prints one
`CAELESTIA_TILING_STATUS tiling=<mode> included=<n> excluded=<n>
status=<status>` line, bridges `toastDecision` to `Toaster.toast` (Warning /
Error, icon `view_quilt`) and localizes copy through `Tr.tr` like upstream
daemons.

Fitting failures (`windowTilingFailed(address, reason)` with `min-size`,
`off-target`, `correction-limit`, `unresponsive`) are recorded in a 20-entry
list with the address-resolved app class/title and explained with the agreed
copy ("Couldn't tile <App>", reason-specific message, "a window" fallback).
Rate limits: one toast per address per reason per enabled session; three
failure toasts per ten seconds; excess collapses into one
"Some windows couldn't be tiled" toast per window. An enable refusal emits
one error toast ("Tiling is off" with the mutex/no-screen message).

The [tiling prototype](../../tiling-prototype/README.md) stages the slice,
the real Hypr facade (for optional failure-name resolution behind
`CAELESTIA_WINDOWS_HYPR=1`), a `Notifs` adapter answering the toast surface's
`hasFullscreen()` with a truthful false, and the original
`Toasts`/`ToastItem` components through a host wrapper that imports them as
a `qs` module. `Start-ShellPrototype.ps1` gained the `tiling` row
(`-Tiling`, `-TilingMode Disabled|Observe|Interactive`, plus
`-TilingIncluded`/`-TilingExcluded`; smoke forces Interactive down to
observe in the child environment) and `Stage-ShellPrototype.ps1` gained the
`tiling` slice. No `WindowManager`, `Taskbar` or keyboard shortcut is
staged.

## Commands and results

All commands were run from the worktree with the shared build and Qt prefix:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'

powershell -NoProfile -File windows/scripts/Test-TilingService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-TilingPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-HyprPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen tiling fixture | **139 assertions**, exit 0, no Quickshell import in the state object, no staging hash mismatch, no QML diagnostics | [result](evidence/tiling-fixture-result.json), [stdout](evidence/tiling-fixture.stdout.log), [stderr](evidence/tiling-fixture.stderr.log) |
| Tiling native matrix | **4/4 runs passed**: fixture, Disabled smoke on both measured screens, M1 regression | [matrix](evidence/tiling-prototype-result.json) |
| Disabled at 150% (screen 0) | Pass; exactly one `CAELESTIA_TILING_STATUS tiling=off included=0 excluded=0 status=disabled` line, no `CAELESTIA_TILING_BACKEND_READY`, no wrapper, no enable, counts 0, original toast surface loaded (`toastSurfaceWidth` 406) | [stdout](evidence/tiling-disabled-screen0.stdout.log), [stderr](evidence/tiling-disabled-screen0.stderr.log), [png](evidence/tiling-disabled-screen0.png) |
| Disabled at 175% (screen 1) | Pass; same invariants | [stdout](evidence/tiling-disabled-screen1.stdout.log), [stderr](evidence/tiling-disabled-screen1.stderr.log), [png](evidence/tiling-disabled-screen1.png) |
| M1 bar/session regression | Pass; no tiling wrapper, no tiling status line | [stdout](evidence/m1-regression.stdout.log), [png](evidence/m1-regression.png) |
| Hypr slice regression (Disabled) | **4/4 runs passed** unchanged | [matrix](evidence/hypr-prototype-result.json) |
| Desktop identity | Work areas, taskbar and installed-shell processes identical before/after both matrices | [before](evidence/desktop-before.json), [after](evidence/desktop-after.json) |
| qmllint over the staged slice | Informational record; Quickshell/Caelestia types are unresolved outside the runtime, and no syntax finding names a new file | [qmllint](evidence/qmllint-staged.txt) |

The smoke state also proves the loader boundary end to end:
`backendRequested=false` while the status line and every count stay at their
disabled defaults, and the M1 host that never stages this slice prints no
tiling line at all.

## Untested items

- All native Observe behavior: constructing the backend `Tiling` singleton
  (which runs `rescueParked()` and can move windows a previous run parked
  off-screen), applying `excluded`/`included` to the real controller, and
  the construction side effects documented in the M3-1 audit.
- All native Interactive behavior: the allowlist gate against a real
  `included`-capable backend build, the tiler mutex, `enableRefused`
  delivery, enabling laying out windows, disable/quit restore and crash
  rescue. The shared build pins a backend without those members, so
  interactive would refuse today even if run.
- Real toasts on screen: the fixture proves every decision, copy string and
  rate limit through the recorded `toastDecision` signal, and the original
  surface loads in the native host, but no native run produced a visible
  toast (Disabled decides none by design).
- Telemetry projection from a real backend (`managedCount`, `failedCount`,
  `lastError`, both signals): exercised only against fakes; the pinned
  backend does not expose them.
- The script-level smoke downgrade of `-TilingMode Interactive` (the
  launcher's env rewrite) was code-reviewed and is mirrored by the
  service-level downgrade proven by the fixture, but no native interactive
  smoke was run.

No environment report was rerun: this slice changes no dependency pins or
setup instructions. No runtime success beyond the Disabled smoke above is
inferred from source parity.

## Review follow-up

An independent review of `a8538ea9` blocked the slice on five findings. The
orchestrator fixed all of them in the follow-up commit:

1. A lone `title:` counted as an allowlist rule, but the backend drops it and
   reads an empty compiled allowlist as unrestricted. `parsePatternList` now
   drops the same entries the backend drops (`tiling_scope.cpp`
   `ScopeRules::compile`).
2. `configure()` assigned the mode before the lists, so the facade's Loader
   attached against an empty allowlist and valid Interactive startup never
   requested enabling. The mode is now assigned last. The fixture covers this
   with a Loader-shaped synchronous attach.
3. Policy refusals (empty or unsupported allowlist) produced no toast. Each
   refused attempt now emits one `Tiling is off` error toast, and the facade
   connects its toast bridge before `configure()`.
4. The summary toast was a fourth toast in a ten-second window. It now takes
   the third slot.
5. The `unresponsive` copy claimed the app stopped responding. Per the
   backend, the window ignored the move and was floated: "It didn't accept
   the move, so it was left floating."

Rerun at the follow-up commit with the same commands: `Test-TilingService.ps1`
passed with 161 assertions, and `Test-TilingPrototype.ps1` passed. Only
Disabled-mode native runs were made.
