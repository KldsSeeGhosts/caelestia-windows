# Wallpaper Engine quick smoke, 2026-10-26

Implementation source: `27ae336c62ef4d85f178bc56827db8ad48129963`, clean.
Combined base: `6abba7ba63a7bc8dfc9748d4b3a32e6ced1d92a7`.
Background reference: `080558870e5848373fdc3f5236cea025f0b10073`.
No dependencies, binaries, authentication or desktop settings were changed.

Runtime reused read-only from
`D:\AiStack\caelestia-windows\windows\.local\build`: Qt 6.11.2, backend
`525786fc81f13346cb196dca5ab356f89ad707a5`, native primary display at 150%.
`build.json` describes that existing binary build, not a new build.
Scheme CLI revision: `5e804b10c146c9f3278b2da37c8e4b5d8e9708d9`.
`environment.json` is only a prerequisite report; ordinary PowerShell PATH
does not expose all compiler tools.

| Check | Observed result | Evidence |
| --- | --- | --- |
| Combined smoke | Pass, 35.7 s, exit 0, no runtime warnings/errors | `result.json`, `combined.*.log` |
| Native WE discovery | Running, installed, 253 workshop projects | `discovery.json` |
| Active Monitor0 | Autum In Japan Pixel Art, project 2456741440 | `discovery.json` |
| Dynamic palette | 74 keys loaded; primary `#f9b7a3` | `combined.stdout.log` |
| Original wallpaper carousel | Count 253, previews and titles rendered | `picker.png`, `CAELESTIA_WE_CAROUSEL` |
| Background coexistence probe | Zero background screens, DesktopLayer inactive, clock off | `background-result.json`, `background.*.log` |
| Animated GIF scheme | Frame-zero generation succeeded, primary `#acc9ea` | `gif-result.json` |
| User wallpaper preservation | Both monitor project/preview selections unchanged | `discovery.json`, `background-result.json` |

Commands, from repository root:

```powershell
$qt = 'C:\Users\Ermin\AppData\Local\caelestia-dev\Qt\6.11.2\msvc2022_64'
$build = 'D:\AiStack\caelestia-windows\windows\.local\build'
'{"windows":{"wallpaperEngine":{"enabled":"auto","picker":"engine","monitor":"Monitor0"}}}' |
    Set-Content windows/.local/we-settings.json -Encoding utf8
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qt -BuildRoot $build -Combined -Smoke `
    -WindowsConfigPath windows/.local/we-settings.json
powershell -NoProfile -File windows/validation/2026-10-26-wallpaper-engine/Probe-Background.ps1 `
    -QtPrefix $qt -BuildRoot $build
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

The short background probe ran at clean `6cedaff4` using that implementation's
guarded WindowsBackground and the reference branch's original background
dependencies. The subsequent `27ae336c` change only delays the combined smoke
picker close by one tick to permit asynchronous screenshot capture.
`Probe-Background.ps1` reproduces the isolated mixed-source load without
enabling the desktop layer. Its artifacts go to ignored `windows/.local`.
No staged QML or per-run `sources.json` is archived.

The GIF check used the existing venv Python to run
`windows/scripts/scheme/win_scheme.py apply-wallpaper --image <preview.gif>
--smart 1`, with `CAELESTIA_PROFILE_ROOT` set to the ignored
`windows/.local/we-gif-profile`. The input was discovered project 1166101323,
`(1080P) Ymir - Call of Silence (Attack on Titan)`. This only writes isolated
scheme state; it never calls Wallpaper Engine.

Preliminary runs exposed launcher Loader context warnings and an unknown C++
config key warning. Those runs were rejected. The final logs are warning-free
after fixing loader lifetimes and using the watched `windows.json` sidecar.
The first picker screenshot closed too early; only the corrected capture is
archived.

Limits: this is a quick smoke, not release validation. Official CLI switching
is implemented but was deliberately not invoked. External user-driven wallpaper
switches, playlist transitions, non-default monitors, enable/disable toggles,
WE restart and failure recovery were not live-tested. The desktop background
module is carried guarded for merging with `t3/background`, but is not staged
by the dynamic-scheme branch's ordinary combined host. No takeover occurred.
