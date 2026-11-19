<img src="assets/icon.svg" width="64" height="64" alt="">

# Caelestia capture helper

`caelestia-capture.exe` is the in-tree Windows recording helper. The Caelestia
shell owns the screenshot picker, editor, thumbnails and recording region
selection. See [capture keybinds](../docs/KEYBINDS.md#screenshots-and-recording).

The helper owns Windows Graphics Capture, Media Foundation H.264 encoding,
audio, the recorder journal and MP4 finalization. It accepts an explicit
fullscreen or physical-pixel region target. Use `--no-ui` when another client
owns the recording controls. The tray can stop an active recording, edit or
reload settings, and exit. It does not start a picker or register capture hotkeys.
See [the recorder protocol](docs/control-protocol.md).

Recorder preferences live at `%APPDATA%\Caelestia\capture\config.toml`. On first
use the helper copies legacy Glazier settings if present. No user file is
rewritten to remove the retired keys. The helper reads `recording_directory`,
`recording_fps`, `filename_format`, `theme_file`, `show_thumbnail`, and
`thumbnail_seconds`. By default it saves to the Videos known folder under
`Screen Recordings`, at 30 fps, and shows a recording preview for six seconds.
Screenshot preferences are separate and belong to the shell.

## Build

Use the shell's reviewed Windows toolchain and production build, which builds
this source with `--locked` and stages `caelestia-capture.exe`. No separate
repository or upstream release is required. See [origin attribution](ORIGIN.md).

```powershell
powershell -NoProfile -NonInteractive -File windows/scripts/Test-CaptureRust.ps1 `
  -ToolRoot D:/tools -OutputRoot D:/validation/capture-rust -Jobs 2
```

Run the command from the repository root with a new output directory. It selects
the pinned compiler, compiles with `cargo test --locked --no-run
--message-format=json`, then executes Cargo's exact test binary from a fresh
owned TEMP cwd with a synthetic profile. It checks the reviewed noninteractive
allowlist before execution. `capture-rust.json` records actual counts, exact
source/lock/toolchain identities, binary hash and all native acceptance reasons.
Raw paths/logs remain local. Empty execution, unreviewed tests, compiler failure
or a failed test makes the gate fail. No ignored test runs in public CI.

The private pipe fixture uses an owned message-only HWND and a process-unique
pipe, never the installed host. Filesystem tests use synthetic paths. Existing
ignored native fixtures cover recording controls, encoding and file drag data.
The retired Rust picker tests were replaced by the shell's picker, editor,
thumbnail and recording regressions. Offscreen results do not claim new
physical display, audio-device, or hardware-encoding coverage.

## Credits

Editor behavior and the original toolbar design are from the Noctalia Screen Toolkit
(`noctalia-dev/legacy-v4-plugins`, MIT). Icons are Tabler Icons (MIT), from
the font bundled with Noctalia shell. See `THIRD_PARTY_NOTICES.md`.
