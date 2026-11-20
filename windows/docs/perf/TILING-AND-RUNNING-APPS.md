# Tiling and running-app performance audit

This audit compared the shell at `bc56c7b7` and its backend at `8be603d3` with two local changes. The tests use Windows and Qt 6.11.3. They measure tile placement work and the running-app model, not frame rate or whole-shell CPU.

## Tiling

The native window tracker collects change notifications. The tiler coalesces dirty windows and layouts on a 30 ms timer. Each dirty layout computes its tree, converts boxes to physical window frames, and places eligible windows. A separate pass verifies where windows landed. Previewing a drop simulates the tree change before committing it.

Converting a box to a frame used to ask the whole tree how many windows owned slots. That materialized the window list for each tile and repeatedly queried native state on the first eligible windows. Scrolling also paid that cost, although its tree had already applied the outer gap. The backend now computes gaps once per geometry pass. It still checks eligibility immediately before placement. The gap value does not survive a pass, monitor change, or change to a simulated tree.

| Layout | Peak style reads on one window, 4 windows | Peak style reads on one window, 16 windows |
| --- | ---: | ---: |
| Master | 42 to 24 | 114 to 24 |
| Dwindle | 42 to 24 | 114 to 24 |
| Scrolling | 48 to 24 | 120 to 24 |

These are `GetWindowLongPtrW` calls during one steady-state layout application, counted at the fake Win32 boundary. The same test, `applyDoesNotRequeryGapOwnersForEachPeer`, ran against both backend revisions. All three rows failed the bounded-work assertion on the original and passed on the candidate. The rest of the windows still need their own placement checks.

Drag previews also used to compute before-and-after frames for a displaced-window outline in all three layouts. Only Dwindle draws that outline. Master and Scrolling now skip that comparison but still calculate the landing frame, including on an empty destination monitor. The drag fixture checks that the preview matches the committed placement.

## Running-app bar

Every change to the native observations can rebuild the bar's window groups. For each app, the original projection filtered the entire visible window list to find that app's members. The new projection walks the stable list once and appends each handle to its group. It preserves the order of restored, previously cloaked windows.

| Synthetic workload | Group membership checks or assignments per rebuild, before / after | Median batch time, before / after |
| --- | ---: | ---: |
| 24 windows, 12 apps, 2,000 rebuilds | 288 / 24 | 227 / 144 ms |
| 120 windows, 40 apps, 400 rebuilds | 4,800 / 120 | 475 / 172 ms |

The offscreen Qt test imported the original and candidate `RunningApps.js` side by side. It seeded the window order, reversed the input enumeration, compared serialized projections, and timed five batches with alternating run order after warmup. Only the grouping pass has the operation counts above. These timings are illustrative, not estimates of the time a user waits for the bar to render.

## Idle work and remaining questions

- The shell already stops dashboard statistics sampling when the last dashboard closes. The clock uses minute precision unless a visible consumer requests seconds. The recorder's default route stops polling after its idle baseline; the classic tray route can start recording outside the shell, so its status poll still has a purpose. No change to these timers.
- A focus change still visits every managed window to refresh border colours. Windows whose desired colour already matches avoid the DWM write, but the eligibility checks can still cost work. The next useful measurement is native state reads during a focus-only switch at different window counts, including fullscreen exit. This audit did not change the border lifecycle.
- A wallpaper selection uses the active-project status scan rather than walking the entire Workshop catalogue. An enabled or running Wallpaper Engine can still start a Python helper every 15 or 60 seconds. Before changing that policy, measure helper starts and CPU with the engine stopped, idle and rendering, and verify external wallpaper changes still reach the shell.

The five native tiling fixtures passed 528 cases. The running-app suite passed 11 tests. No live window moves, focus switches, hardware traces, or production release builds were part of these measurements.
