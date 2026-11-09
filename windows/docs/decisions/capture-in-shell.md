# Capture in the shell

Status: accepted design for #71. The owner approves each phase's final result.

Roles: the orchestrator owns this design and final approval. Sonnet 5.5 implements, and GPT 6.1 Sol reviews each PR.

## Decision

Screenshot capture becomes part of the Caelestia shell:

- **Shell (QML):** the picker, the editor, the post-capture thumbnail and the recording controls.
- **In-tree Rust helper (`caelestia-capture.exe`):** recording encoding, the recording journal and file ownership (#28), and the legacy path behind a setting.

The tool is a Caelestia component. It uses Caelestia's controls (`IconButton`, `IconTextButton`, `TextButton`, `ButtonBase`), tokens (padding, spacing, rounding, font), fonts and wording, so it follows the live scheme, the display scaling and Caelestia motion. The current Rust tool is a reference for behaviour only, meaning what the user can do. Its pixel sizes, labels and look are not copied.

## Why

- **Stacking and input (#69).** The picker becomes an overlay-layer Caelestia panel. When the backend raises a top-layer panel, `restack(..., raiseOverlays)` places overlapping overlay panels above it in one batch, and `restoreTopmostPanels` does the same (backend `src/windows/panel_window.cpp:403, 416-447`). An unmasked overlay panel receives every press, including over the bar and border.
- **One owner and one UI language.** Today two processes coordinate through a host registry, surface dismissal and a hidden-surface timer (`windows/shell/adapters/services/Glazier.qml:91-214`). The picker removes that handshake for screenshots.
- **Upstream alignment.** Upstream's picker (`modules/areapicker/AreaPicker.qml`, `Picker.qml`) is the starting point. The IPC names (`picker open/openFreeze/openClip/openFreezeClip`) and shortcut names are already upstream's.
- **Colours are not a reason.** The current tool already follows the scheme. `ThemeTokens.qml` writes `theme-tokens.json`, and the helper reloads it on every capture (`windows/capture/src/host.rs:271-273`).

## Look

Use Caelestia's controls, tokens, fonts and wording. Take what the user can do from the current tool, and nothing about how it looks.

Rules for every control the tool draws:

- **Controls.** A button is a Caelestia control. Icon-only tools and actions are `IconButton` (text type). Labelled buttons such as Copy and the armed "Clear all?" are `IconTextButton`. The size buttons are `TextButton` and the colour cells are `ButtonBase`. A missing feature is added through the control's existing properties or by wrapping it, never by copying the control.
- **Sizes.** A size is a control's implicit size or a `Tokens` value. No pixel constant comes from the Rust tool. `EditorLogic.js` and `ThumbnailLogic.js` receive the measured sizes and the token values, and they decide where things go.
- **Device pixels.** Every position and size that the logic returns is rounded to a whole device pixel, so text stays sharp at 125%, 150% and 175% scaling. A size rounds up and a position rounds to the nearest pixel. The controls add logical-pixel offsets of their own (padding, centring, the icon nudge), so the final position of each label and icon is whole only if the code also snaps it. The bar, the popover and each thumbnail card start on a whole device pixel, and `PixelSnap.qml` moves every label and icon in them to one. `CapturePixelsTest.qml` maps each of them to the window and checks at 100%, 125% and 150%.
- **Wording.** Labels and tooltips are short, in sentence case, and written the way the rest of the shell writes them. They go through `Tr.tr()`. A tooltip is the attached `ToolTip` with the shell's 500 ms delay.
- **Fonts.** Text takes the control's font (`Tokens.font.body.small` for labels, `Tokens.font.icon.medium` for icons). The tool sets no font of its own.

| Element | What it uses |
|---|---|
| Colours | `Colours.palette.m3*`, with the roles of the controls. Tint and solid use surfaceContainer, edge and divider use outline or outlineVariant, the chosen tool uses secondaryContainer, Copy uses the filled button's primary, danger uses error |
| Toolbar | One row of Caelestia controls. Padding is `Tokens.padding.small`, spacing between buttons `Tokens.spacing.extraSmall`, between groups and around separators `Tokens.spacing.small`. Radius is `Tokens.rounding.large`. Placement: below the selection, otherwise above, otherwise inside, kept a `Tokens.spacing.small` margin from the work area's edge, draggable |
| Glass | Caelestia elevation for the shadow. A `MultiEffect` blur of the frozen image under the surface, which is cheap because the image is static. Rounding and padding from Tokens |
| Popover | A row of colour cells (`ButtonBase`) and a row of S, M and L size buttons (`TextButton`), opened above the bar or below it |
| Icons | Material Symbols through the controls' `MaterialIcon`, as in the rest of the shell |
| Motion | Caelestia `Anim` types: default spatial for the tool indicator and standard for fades. Respect the shell's reduced-motion handling |
| Picker | 30% tint outside the selection, 2 px primary outline, cross cursor. The tint is surfaceContainerHighest at 30%. The outline radius stays 0 to match the selection |
| Editor wash | 55% black outside the selection |
| Thumbnail | Bottom-right stack of 5, 6 s timeout, click reopens the editor, drag-out. The hover row (Copy, Save, Show in folder, Close) is a row of `IconButton`s with tooltips. The card keeps its 260 x 174 size for now |
| Recording controls | Record, Pause, Stop, Mic, Sound and Discard, a pulsing dot and an MM:SS timer, driving `Recorder.qml` |

## Architecture

### Picker

- **Source:** upstream `AreaPicker.qml` and `Picker.qml`, staged through `windows/shell/sources.json`. Windows replacements live in `windows/shell/adapters/modules/areapicker/`, following the ClipboardOverlay pattern (`windows/services/clipboard/ClipboardOverlay.qml:302-328`).
- **Windows:** one `StyledWindow` per screen.
  - `WlrLayershell.layer: WlrLayer.Overlay` and `exclusionMode: Ignore`.
  - `keyboardFocus: Exclusive` while open.
  - New `excludeFromCapture: true` (see Backend).
- **Selection:** cannot span monitors, which matches upstream. The current tool allows it, so this is an accepted change. With mixed scaling, a cross-monitor image has no single correct scale.
- **Focus:** keybinds arrive through the shell's keyboard hook, which grants the foreground right (`activation_policy.hpp:26-45`). An IPC open may not get keyboard focus, so right-click cancels as well as Esc.

### Freeze

- When opened, each screen's window shows a `ScreencopyView { captureSource: screen; live: false }`.
- Because the window is excluded from capture, the grab contains the desktop, the apps, the bar and the border, but never the picker. This fixes the risk that the tint or fade-in ends up in the image.
- The tint stays invisible until every screen reports `hasContent`, so the user never sees a partial freeze.
- Budget: first frame on both of the owner's monitors within 100 ms of the key press. Measure it in phase 2. If it misses the budget, the fallback is a backend one-shot all-monitor grab into an image provider.
- Upstream's non-freeze mode hides the `ScreencopyView` before activating it. The Windows `ScreencopyView` never starts capturing while invisible (backend `screencopy_view.cpp:283-286`). With `excludeFromCapture`, the adapter does not need to hide anything. It keeps the view visible and lets the excluded window stay on screen.

### Window and monitor mode

- **Monitor mode:** hovering a monitor with no window under the cursor selects the whole monitor, as today.
- **Window mode:** needs the topmost window under the cursor. The Hyprland toplevel shim is not z-ordered (`hyprland/connection.cpp:495`). A new backend snapshot, taken when the picker opens, returns visible application windows in z-order with their frame bounds (`DWMWA_EXTENDED_FRAME_BOUNDS`, as `window_tracker.cpp:314-320` already computes). The picker hit-tests that list top-down.

### Output

- **Export:** `CUtils.saveItem(item, url, rect)` (`plugin/src/Caelestia/cutils.cpp:32-79`). The item is the editor's composed item (frozen image plus annotation layer), at the native pixel scale.
- **Gate:** phase 2 must prove that `grabToImage` reads back a Windows `ScreencopyView` (a D3D11 texture) correctly. If not, the backend adds `ScreencopyView.saveFrame(path, rect)`, and the editor composes the strokes over the saved frame.
- **Clipboard:** `Clipboard.copyImageFile(path)` writes CF_DIB only. The current tool writes PNG and DIB. Adding PNG is a backend follow-up, not a blocker.
- **Files:** the default save directory is Pictures\Screenshots, then Pictures. Names use the current `filename_format` default, with " (n)" numbering. The clipboard hand-over image goes in the OS temp directory as `caelestia-clipboard-<UUID>.png`, not `/tmp`. The picker deletes only its own file, and a crash in the middle of a save can leave one file behind.

### Editor

- The editor opens in place over the selection. Tools and shortcuts as today: Pencil P, Highlighter H, Line L, Arrow A, Rectangle R, Circle C, Text T, Blur B, Step N, Ruler M.
- Also: right-click eraser, Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z, Ctrl+C copy, Ctrl+S save, colour popover (the 9 colours), sizes S/M/L, Clear with confirmation, New capture, Close, zoom 1-5x, compact toolbar with group flyouts.
- Strokes are a model in a JS module, so the geometry is testable with node. Rendering uses QtQuick Shapes. The specific behaviours:
  - Pencil width from speed.
  - Arrow head at max(size x 3.5, 10) with a half-angle of pi/5.
  - Steps renumber after undo or erase.
  - The ruler label is rotated and shows pixel lengths.
- Blur is a 20 px pixelation of the frozen image: a `ShaderEffect`, or a pre-pixelated copy made once.
- Keep the current zoom behaviour, except that export while zoomed includes the strokes. The current version drops them (`overlay.rs:1221-1224`), which is treated as a bug.

### Thumbnail

An overlay panel, also excluded from capture, bottom-right of the work area. It behaves as today, including dragging the image out.

**Drag-out.** Pressing the card body and moving past the system drag distance (`SM_CXDRAG` and `SM_CYDRAG`, in device pixels, either axis) drags the image into another program. A press on an action button never starts a drag, and a click that does not move opens the image as before.

- **Where it lives.** The shell plugin, not the backend. `CUtils.startImageDrag(path, item)` (`plugin/src/Caelestia/imagedrag.cpp`) runs a Qt `QDrag` with copy as the only action, and `item` is the card's image, which gives the drag picture. The pinned backend is unchanged. Qt's Windows data object supplies the formats, so there is no hand-written OLE code.
- **What the target receives.** The real file as `CF_HDROP`, the decoded image as `PNG`, `CF_DIB` and `CF_DIBV5`, the file as a `UniformResourceLocator(W)` link, and `Preferred DropEffect` set to copy. A target takes the format it prefers. `plugin/src/Caelestia/Windows/test/imagedrag_desktop_test.cpp` reads these back through OLE.
- **Which file.** A saved capture drags its saved file. A copy-only capture drags a file of its own, the drag file (see below), not the card's preview file. A drag never saves a copy-only capture and nothing reaches the screenshots folder. Esc, or a drop where nothing accepts it, changes nothing.
- **Who owns the drag.** `imagedrag::run` allocates the `QDrag` on the heap, under a parent object that exists only for the call. The drag runs a nested event loop (OLE's), and a shell reload can destroy the `CUtils` singleton, the card and the QML engine objects inside that loop. The drag does not belong to any of them, so none of them can free it, its mime data or its picture. If the object that asked for the drag is destroyed meanwhile, the drag is cancelled with `QDrag::cancel()`. The drag, data and picture are freed after the loop returns, and nothing touches the asking object after that. `plugin/src/Caelestia/Windows/test/imagedrag_test.cpp` destroys the source, a deferred-deleted source and the source's parent inside a loop, and checks that nothing is freed until the loop ends and then exactly once. The offscreen platform's drag returns at once, so those cases run their own loop through the test seam of `run`; the real OLE loop needs a pointer and is covered only by the owner's live check.
- **The card during a drag.** The drag runs its own message loop, so the owner marks the preview as dragging for its duration. The timeout does not count meanwhile, and the card does not slide, close, get pushed out by a sixth capture or lose its file. A close that arrives meanwhile (timeout, Close, the thumbnail being turned off, a removed screen) happens when the drag ends. The timeout then goes on from where it stopped, as after hover.
- **The drag file.** The target sees the file's real name, so a copy-only capture gets a file with a normal screenshot name. The temp scheme of the hand-over files (`CUtils.newCaptureTempPath` and `removeCaptureTemp`, unchanged) allows only `caelestia-clipboard-<uuid>.png`, so the drag has a second, equally strict scheme.
  - **Scheme.** `CUtils.newDragFile(name)` creates the directory `<temp>\caelestia-drag-<uuid>\`, which must not exist yet, and puts the empty file `name` in it. `name` is the default Save name, `annotate-<stamp>.png` (the `filename_format` default that the picker's Save uses), made when the first drag starts. The call fails and leaves nothing behind for a name that is not one plain `.png` file name (separators, `..`, `:`, characters Windows forbids, reserved device names, trailing dots or spaces). The shell copies the card's preview file into it.
  - **Remover.** `CUtils.removeDragFile(path)` accepts only the exact path `<temp>/caelestia-drag-<32 lower case hex digits>/<valid name>`. It then works through handles, not paths, so another process cannot redirect the delete by swapping the directory after a check. It opens the drag directory without `FILE_SHARE_DELETE`, which stops every other process from renaming, deleting or replacing it while the handle is open. The handle must be a directory, not a reparse point, and its final path must be exactly `<resolved temp root>\caelestia-drag-<uuid>`. It lists the pinned directory through the handle, hidden and system entries included, and requires no entry besides the one file. It opens that file with `FILE_FLAG_OPEN_REPARSE_POINT`, requires a regular file with one hard link and the expected final path, and deletes it through its own handle (`FileDispositionInfoEx` with POSIX semantics, falling back to `FileDispositionInfo`). It then deletes the empty directory through the pinned handle, which fails while the directory still has entries. There is no globbing, no recursion and no scan for unknown directories. It refuses other paths, nested paths, reparse points, hard-linked files, a final path that is not the expected one and extra entries, and deletes nothing in those cases. It returns true when the directory is gone afterwards, and also when it was already gone.
  - **Creation.** `CUtils.newDragFile` creates the directory with `CreateDirectoryW`, which fails when the name exists, and then opens it pinned and checks it as above. Only after that check does it create the file with `CREATE_NEW`, which fails when the name exists. Both objects are rolled back only if this call created them, and only through the handle opened at creation: the file through its own handle, the directory through the pinned one. A rollback never deletes by path. When the directory check fails, because something replaced the new directory between `CreateDirectoryW` and the open, nothing is deleted. The empty directory the call made stays in the temp directory, which is the accepted cost of not guessing what the path now names. When `CREATE_NEW` fails, nothing is deleted either, and the directory stays if it is not empty.
  - **Temp root.** The root is resolved once per call by opening it and reading its final path, so a `%TEMP%` that is itself a junction or has 8.3 names works: the drag directory must have the final path `<resolved root>\caelestia-drag-<uuid>`, which a directory reached through a swapped root does not have. The root itself is not held open, so a swap of the root between the resolve and the open is caught by that final-path comparison, not prevented. One gap remains: another process that replaces the new directory with a different real directory in the instant between `CreateDirectoryW` and the open is treated as the new directory. The only effect is one empty file of ours in a directory that the other process made. Nothing outside that directory is touched.
  - **Lifetime.** A target can read the dropped path later (a deferred upload records it at Drop and opens it afterwards), so the file must outlive the drag call. `Thumbnails.qml` keeps the exact paths it made in memory. A drag file is removed when both hold: its card has closed (Close, timeout, eviction by a sixth capture, a removed screen, the thumbnail being turned off), and at least 5 minutes have passed since its last drag ended. Removal runs on a timer while some card has closed, and at every new capture. A file that cannot be removed yet, for example because a target holds it open, stays and is tried again. A repeated drag of the same card reuses its drag file while it exists. A saved capture drags its saved file and makes no drag file.
  - **Accepted risk: the copy into the drag file.** The shell copies the preview into the new file by path, after `newDragFile` returns and the directory is no longer pinned. A process that swaps the directory for a junction in that window could make the copy overwrite a same-named PNG elsewhere. `%TEMP%` is private to the user's account, so only a process already running as that user could do this, and such a process can already overwrite the user's files directly. The owner accepted this risk on 2026-11-08 rather than spend more review rounds on it.
  - **Shutdown.** A clean shutdown or reload removes every remaining drag file at once, whatever its age (`Component.onDestruction` of the thumbnail scope, and the application's `aboutToQuit`). After a crash the file and its directory can stay in the temp directory, the same accepted gap as the clipboard hand-over file. The retry list is memory only and teardown cannot block, so a file that a target still holds open when the shell reloads or quits is not tried again and stays in the temp directory. That is an accepted gap of the same kind as the crash, and no bulk cleanup of unknown `caelestia-drag-*` directories is added.
  - **Tests.** `plugin/src/Caelestia/Windows/test/dragfile_test.cpp` covers the scheme and the remover, including swaps. A test seam compiled only into that test target (`CAELESTIA_DRAGFILE_HOOKS`) runs a callback between two steps, so each swap test changes the file system at the exact moment a race would and does not depend on timing: the directory swapped for a junction while held, a file swapped for a hard link or a junction, a root swapped after it was resolved, a failed directory check and a failed `CREATE_NEW` rolling back nothing, and a junction as the temp root. `windows/tests/CaptureThumbnailTest.qml` covers the lifetime rules on an injected clock: the card closing before and after the grace period, a sixth capture evicting a card, a locked file, and shutdown.

### Recording

- The QML picker selects the region. The helper still encodes.
- **Protocol:** `record` gains an optional `region` field (`{x, y, w, h}` in physical virtual-desktop pixels, even-cropped by the helper) and `ui: false`, which suppresses the helper's own border and controls. Use a new optional field with protocol version 1. The bundled helper and the shell ship together, and the decoder change is additive. A legacy `glazier.exe` override does not support it, so the shell falls back to the classic flow for overrides.
- **Shell side:** the QML border and controls drive `Recorder.qml` (`stop`, `--pause`/`--resume`, mic and sound). Both are excluded from capture, so they never appear in the video.
- The journal, file ownership, finalisation and recovery stay in Rust, unchanged.

### Setting and compatibility

- `windows.capture.ui` in `config/shell.json` is `"classic"` (the current tool) or `"shell"`. The default is `"classic"` until phase 5. A legacy `glazier.exe` override always uses classic.
- Every entry point routes through one shell function that picks the path:
  - PrintScreen and Win+Shift+S;
  - launcher Screenshot and Record;
  - IPC `screenshot capture` and the `picker` functions;
  - the `record` shortcut.
- The `Glazier.qml` IPC handlers and the `windows/shell/adapters/daemons/Shortcuts.qml` calls (`:38-72`) move to that function. The names are unchanged.
- **Reload:** a shell reload closes an open picker or editor without saving. Recording is unaffected because the helper owns it.

## Backend work (backend PR first, then a shell pin bump in all three places)

1. **`excludeFromCapture`** on panel windows: `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, which falls back to no effect on systems without it. Include a fixture test.
2. **Window stack snapshot** for QML: visible, non-cloaked, non-shell application windows in z-order, with frame bounds in Qt logical global coordinates. Include a fixture test.
3. **Only if phase 2's gate fails:** `ScreencopyView.saveFrame(path, rect)`.
4. **Follow-up, not blocking:** PNG clipboard format. The drag source for files is not backend work: the thumbnail's drag-out uses Qt's `QDrag` in the shell plugin (see Thumbnail).

## Phases and PRs

| PR | Repo | Content | Depends on |
|---|---|---|---|
| 1 | shell | This design doc in `windows/docs/decisions/capture-in-shell.md` | none |
| 2 | backend | `excludeFromCapture` and the window stack snapshot | none |
| 3 | shell | Pin bump to 2 | 2 |
| 4 | shell | Picker behind `windows.capture.ui: "shell"`: freeze, region, window and monitor modes, copy and save without the editor (a straight capture), the routing function, `sources.json` entries. Measures the freeze time and settles the `grabToImage` gate | 3 |
| 5 | shell | Thumbnail | 4 |
| 6 | shell | Editor, part 1: toolbar, glass, colour and size popover, Pencil, Highlighter, Line, Arrow, Rectangle, Circle, undo/redo, Clear, copy and save | 4 |
| 7 | shell | Editor, part 2: Text, Blur, Step, Ruler, eraser, zoom, compact toolbar and flyouts, tooltips | 6 |
| 8 | shell | Helper `record` region and `ui:false` (Rust and tests), QML recording border and controls | 4 |
| 9 | shell | Default switches to `"shell"` after the owner's live check; docs; KEYBINDS.md cleanup | 5, 7, 8 |
| 10 | shell | Later: retire the Rust picker, editor and thumbnail code once the shell path has shipped in a release | 9 |

## Tests

- **node:**
  - Selection math, snapping and hit-testing, toolbar placement and clamping.
  - Stroke geometry (arrow, step renumbering, ruler), pencil width, export rect and DPR math.
  - These live in a JS module next to the QML, following the existing `windows/tests/*.test.js` pattern. Do not use regex extraction from QML.
- **QML fixtures** (`Invoke-QmlFixture`, added to the Shell suite list in `Test-Validation.ps1`):
  - Routing between classic and shell, including the legacy override.
  - The picker opens one window per screen and closes on Esc and on right-click.
  - The editor tool state and undo.
- **Backend fixtures:** capture exclusion and the window stack order.
- **Rust:** the control-protocol tests for `region` and `ui`. The existing capture tests stay until PR 10.
- **Live checks** that cannot be automated, for the owner on two monitors:
  - The freeze looks instant.
  - The bar and border are in the image.
  - A drag starts on the bar.
  - Window snapping picks the topmost window.
  - Copy pastes into an app.
  - Save works.
  - The thumbnail.
  - A recording's region and controls stay out of the video.
  - Win+Shift+S focus.
  - Scheme changes recolour everything.
  - Reduced motion.

## Out of scope

- HDR. The SDR sRGB policy in `CAPTURE-COLOR.md` stays.
- OCR, pinning and save-as.
- Cross-monitor selection.
- Changes to the recording encoder.
