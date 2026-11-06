# Local file URL regression

`windows/shell/adapters/utils/FileUrls.js` defines the shared boundary:

- Input without a URI scheme is a raw path. Absolute drive, UNC-share and
  rooted paths become hierarchical `file:` URLs with each path segment
  percent-encoded.
- Input beginning with `file:` is already URL data. A valid URL is preserved
  byte-for-byte. Legacy literal ASCII spaces normalize to `%20`, without
  changing existing escapes. Other malformed URLs, including raw query or
  fragment delimiters, are rejected instead of guessing their intended path.
- Clipboard text decodes once and accepts local references only. Remote
  authorities and leading UNC/device paths, including encoded separators and
  `localhost`-prefixed UNC spellings, stay text with no file path or preview.
  Explicit `Paths`/helper conversion still supports UNC. Its tests only
  compare synthetic strings and `QUrl` results, never access a share.
- Relative shell asset paths and `root:/` resources keep their existing
  resolution path through `Paths.absolutePath`.

Run on Windows with Node.js and a matching Qt 6 SDK/Quickshell runtime:

```powershell
windows/scripts/Test-FileUrls.ps1 `
  -QtPrefix <matching-Qt-sdk> `
  -BuildRoot <read-only-compatible-build> `
  -OutputRoot <external-local-output-parent>
```

`QtPrefix` is required. `BuildRoot` defaults to `windows/.local/build`;
`OutputRoot` defaults to `CAELESTIA_TEST_OUTPUT_ROOT` or the system temporary
directory's `validation-erm630` child. Every invocation creates a new
`file-urls-<guid>` child, retains only that run's synthetic data/stage/profile
and logs, and never cleans up an older run. Outputs inside the checkout or
on UNC paths are rejected. No fixed drive letter is required.

The dedicated runner emits and saves `summary.json` (schema 1, suite
`FileUrls`) with the exact source SHA and dirty flag, parsed Node
tests/pass/fail/cancelled/skipped/todo counts, QML assertion count, exit/timeout
state, runner hash, sanitized commands and diagnostics. Paths in that receipt
use `$REPO_ROOT`, `$OUTPUT_ROOT`, `$BUILD_ROOT`, `$QT_PREFIX`, `$NODE_DIR`
and, when selected, `$RUNTIME_PREFIX`.
It exits nonzero on missing/inconsistent counts, failures, skips or todos,
or a failed QML fixture. Raw logs and retained fixture trees are local-only,
not sanitized upload artifacts. Suite/CI registration belongs to the
validation owner, not this dedicated runner.

The Node suite executes the actual production JS helper and clipboard model.
The offscreen QML fixture uses the production `Paths.qml` and clipboard model,
the actual Qt `QUrl` conversion methods, the native `CUtils.copyFile`, and Qt
`Image` loading. Its filesystem test data are a generated 2x2 PNG and its copy
beneath the owned output directory; runner logs are stored there as well. The
QML harness uses disposable staging/profile directories. No system clipboard,
real profile, wallpaper state or live wallpaper handoff is read or changed.
The fixture's deliberately unescaped `#` URL is a negative control: it must
fail to load while the encoded URL succeeds.

The offscreen preview assertion is not Wallpaper Engine readiness, transition,
or physical desktop acceptance. Both `WallpaperCategory.qml` and
`WallpaperSelect.qml` route their Wallpaper Engine preview paths through
`Paths.absolutePath`; the fixture verifies only that shared file-URL boundary.
Native visible wallpaper acceptance remains NOT RUN, with STOP preserved.
