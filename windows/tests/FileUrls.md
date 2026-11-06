# Local file URL regression

`windows/shell/adapters/utils/FileUrls.js` defines the shared boundary:

- Input without a URI scheme is a raw path. Absolute drive, UNC-share and
  rooted paths become hierarchical `file:` URLs with each path segment
  percent-encoded.
- Input beginning with `file:` is already URL data. A valid URL is preserved
  byte-for-byte; a malformed URL is rejected instead of being decoded and
  encoded again.
- Decoding happens once, only when clipboard text is interpreted as a file
  reference. Unsupported schemes, malformed escapes, query/fragment
  components and incomplete UNC paths produce no local path.
- Relative shell asset paths and `root:/` resources keep their existing
  resolution path through `Paths.absolutePath`.

Run on Windows with Node.js and a matching Qt 6 SDK/Quickshell runtime:

```powershell
windows/scripts/Test-FileUrls.ps1 `
  -QtPrefix <matching-Qt-sdk> `
  -BuildRoot <read-only-compatible-build> `
  -OutputRoot D:\Caelestia\validation-erm630
```

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
