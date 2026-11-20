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
- The first pass found a full border eligibility scan on focus change. The follow-up below addresses it.
- A wallpaper selection uses the active-project status scan rather than walking the entire Workshop catalogue. An enabled or running Wallpaper Engine can still start a Python helper every 15 or 60 seconds. Before changing that policy, measure helper starts and CPU with the engine stopped, idle and rendering, and verify external wallpaper changes still reach the shell.

The five native tiling fixtures passed 528 cases. The running-app suite passed 11 tests. No live window moves, focus switches, hardware traces, or production release builds were part of these measurements.

## Follow-up: focus, wallpaper memory, and clipboard

The follow-up baseline was shell `fd71f8ca` with backend `7f900bd9`. All inputs were synthetic; no personal clipboard, wallpapers, or live windows were used.

| Path | Workload | Result |
| --- | --- | --- |
| Tiling focus | Switch focus with 4 and then 16 tiled windows | Only the previous and new foreground windows incurred border reads or writes in either layout. A palette or layout change still takes the full path. A refused Windows write is retried on a later update. |
| Smart wallpaper preview | First preview of a 7680 × 4320 JPEG, in a fresh worker and empty cache | Median peak working set fell from 281.2 to 154.6 MiB. Median preview time fell from 190.3 to 142.5 ms. All previews returned the same palette. |
| Wallpaper Engine catalogue | 25 checks of an unchanged 2,000-project snapshot | Median comparison time fell from 157 to 51 ms. The shell no longer keeps a separate 359,561-character JSON string for this catalogue. An unchanged status poll also retains the existing display model. |
| Clipboard picker | Build 50 rows: 25 twelve-line notes and 25 two-file lists | File URL parser calls fell from 1,800 to 50, with identical serialized rows. A search can still find a file label beyond the preview limit. No clipboard content is cached between calls. |

For the preview test, Windows `GetProcessMemoryInfo` reported the worker's peak working set. Three fresh processes per revision ran in alternating pairs. The worker sampled the decoded frame before converting to RGB; it did not ask the JPEG decoder for a lower-resolution image. The latter saved more memory but changed the palette. For the catalogue test, Qt 6.11.3 ran five alternating batches against the same parsed records. It measured comparison work only, not workshop enumeration, helper startup, or rendering.

These measurements do not establish a whole-shell idle memory or desktop frame-time improvement. Wallpaper Engine's discovery interval is unchanged.
