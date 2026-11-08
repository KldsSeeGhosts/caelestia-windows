# Capture in the shell

Status: accepted design for #71. The owner approves each phase's final result.

Roles: the orchestrator owns this design and final approval. Sonnet 5.5 implements, and GPT 6.1 Sol reviews each PR.

## Decision

Screenshot capture becomes part of the Caelestia shell:

- **Shell (QML):** the picker, the editor, the post-capture thumbnail and the recording controls.
- **In-tree Rust helper (`caelestia-capture.exe`):** recording encoding, the recording journal and file ownership (#28), and the legacy path behind a setting.

The UI keeps the current capture tool's layout, sizes and behaviour. It is built from Caelestia components, so it follows the live scheme, the rounding and font tokens, and Caelestia motion.

## Why

- **Stacking and input (#69).** The picker becomes an overlay-layer Caelestia panel. When the backend raises a top-layer panel, `restack(..., raiseOverlays)` places overlapping overlay panels above it in one batch, and `restoreTopmostPanels` does the same (backend `src/windows/panel_window.cpp:403, 416-447`). An unmasked overlay panel receives every press, including over the bar and border.
- **One owner and one UI language.** Today two processes coordinate through a host registry, surface dismissal and a hidden-surface timer (`windows/shell/adapters/services/Glazier.qml:91-214`). The picker removes that handshake for screenshots.
- **Upstream alignment.** Upstream's picker (`modules/areapicker/AreaPicker.qml`, `Picker.qml`) is the starting point. The IPC names (`picker open/openFreeze/openClip/openFreezeClip`) and shortcut names are already upstream's.
- **Colours are not a reason.** The current tool already follows the scheme. `ThemeTokens.qml` writes `theme-tokens.json`, and the helper reloads it on every capture (`windows/capture/src/host.rs:271-273`).

## Look

Keep the current geometry and behaviour, and swap the drawing primitives for Caelestia ones.

| Element | Current tool | Shell version |
|---|---|---|
| Colours | theme-token mapping (`theme_tokens.rs:142-199`) | `Colours.palette.m3*` with the same role mapping: tint and solid use surfaceContainer, edge and divider use outline, hover uses surfaceContainerHighest, selected uses secondaryContainer, action uses primary, danger uses error |
| Toolbar | 44 px tall, 6 px padding, radius 14, 30 px buttons with 2 px gaps, 8 px between groups, separators 1 x 18 | Same sizes. Radius from `Tokens.rounding.large`. Same placement rules (`placement.rs:41-68`): 10 px below the selection, otherwise above, otherwise inside; clamped to the work area with a 6 px margin; draggable |
| Glass | Hand-rolled shadows plus a box-blurred backdrop | Caelestia elevation for the shadow. Backdrop is a `MultiEffect` blur of the frozen image under the toolbar, which is cheap because the image is static |
| Icons | Tabler font | Material Symbols through `MaterialIcon`, matching the rest of the shell. Mapping table in the phase 3 PR. The owner may revert to Tabler, which is MIT-licensed and already bundled |
| Font | Segoe UI Variable | `Tokens.font` (Google Sans Flex) |
| Motion | 100 ms cubic ease-out for the hover target and fades; 300 ms back-out for the tool indicator; thumbnail slide-in | Caelestia `Anim` types: fast spatial for target moves, expressive spatial for the indicator, standard for fades. Respect the shell's reduced-motion handling |
| Picker | 30% tint outside the selection, 2 px primary outline, cross cursor | Same. The picker tint is surfaceContainerHighest at 30%, as in the current tool (`overlay.rs` picker tint), not the surfaceContainer that the editor tint and solid use. The outline radius stays 0 to match the selection |
| Editor wash | 55% black outside the selection | Same |
| Thumbnail | 260 x 174, bottom-right, stack of 5, 6 s timeout, hover row Copy/Save/Folder/Close, click reopens the editor, drag-out | Same behaviour as a Caelestia overlay panel with Caelestia motion |
| Recording controls | 52 px capsule, Record/Pause/Stop/Mic/Sound/Discard, pulsing dot, MM:SS timer | Same, driving `Recorder.qml` |

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

An overlay panel, also excluded from capture, bottom-right of the work area. It behaves as today, including dragging the file out. Drag-out needs a native OLE drag source, which the backend may lack. If so, phase 2b ships without drag-out and records it as a gap.

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
4. **Follow-up, not blocking:** PNG clipboard format, and an OLE drag source for files.

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
