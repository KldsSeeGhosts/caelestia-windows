# Windows regression validation

These test sources were selected from the maintainer's archived regression
work and reviewed for public use. They do not import private Git history,
machine profiles, old screenshots, benchmark results or validation archives.
Fixtures use synthetic identities and keys, temporary files and loopback
servers rather than real provider accounts.

## Coverage

- `Test-Validation.ps1 -Suite Unit`: PowerShell syntax, production-map
  isolation, docs, CI path selection, scheme-probe ordering, settings import,
  lifecycle, JavaScript logic and Python quota-provider tests.
- `-Suite Packaging`: version selection, update, rollback, failure recovery,
  scheme-generation identity/receipts, contention, pruning, privacy and
  uninstall contracts. Native launchers and provisioning are faked.
- `-Suite Services`: app catalog, audio, battery/power profiles, Bluetooth,
  brightness, media, network, notifications, session, tiling, tray,
  workspace dispatch and wallpaper-target service contracts.
- `-Suite Shell`: launcher/notification accessibility contracts, drag
  previews, teardown, idle status, launcher hover, fullscreen routing,
  focus-return policy, quota interaction and wallpaper/background ownership.
- `-Suite Scheme`: the real pinned colour generator's worker protocol,
  image downscaling, caching and wallpaper-input handling.
- `Build-Prototype.ps1 -PluginTests` plus CTest: nine native plugin fixtures
  for settings-layer migration, log-redaction policy, clipboard logic and QML
  transport, display-power messages, focus-follows-mouse policy, known
  folders, focus guarding and WASAPI format/downmix decisions. OS mutation
  boundaries are injected or consumed by recording test windows.

Fixture assertion floors and error detection are retained. One background
expectation now distinguishes the engine preview used for colour generation
from the retained local underlay, matching the production ownership contract.
The installer fake launcher carries the metadata required by the current
classic-launcher safety guard.

Run from the repository root:

```powershell
windows/scripts/Test-Validation.ps1 -Suite Unit -Python python
windows/scripts/Test-Validation.ps1 -Suite Packaging
windows/scripts/Test-Validation.ps1 -Suite Services -QtPrefix <qt> -BuildRoot <build>
windows/scripts/Test-Validation.ps1 -Suite Shell -QtPrefix <qt> -BuildRoot <build>
windows/scripts/Test-Validation.ps1 -Suite Scheme -Python <prepared-venv-python>
```

Scheme tests require the CLI revision in `windows/sources.lock.json` and
the hash-locked packages in `windows/scripts/scheme/requirements.lock.txt`.
CI prepares those dependencies in a disposable virtual environment.
Do not run the tests by provisioning or modifying a live profile.

Native plugin fixtures require Qt Test from the same SDK. Configure and build
using the normal build command with `-PluginTests`, then run CTest against
`<build>/caelestia`, with the SDK's `bin` and `<build>/caelestia/lib` on the
current process PATH. Set `QT_QPA_PLATFORM=offscreen` and
`QT_QPA_PLATFORM_PLUGIN_PATH=<qt>/plugins/platforms`.
Use `--output-on-failure --timeout 60 --no-tests=error`; missing Qt Test,
unbuilt executables or an empty registration must fail, not skip.
Test executables are not installed into the product payload.

For local QML regression work, `-RuntimePrefix <immutable-version-directory>`
can replace `-BuildRoot`, using a verified installed release as the native
runner. This does not test rebuilt native changes. The matching developer
Qt SDK must be installed; the harness verifies the Qt Core DLL hash, requires
`qoffscreen.dll` and explicitly supplies its platform-plugin path.
The public installed runtime only needs `qwindows.dll`.

Every QML run stages into a unique temporary profile, requests the offscreen
platform, and supplies fakes for service mutations. Production staging never
includes these fixtures. Output defaults to a unique directory outside the
checkout; use `-OutputRoot` to choose another external location.

## Not covered by these restored gates

The backend's standalone C++ fixtures live and run in the backend
repository (`src/windows/test`, with its own CI for the portable tier).
`Build-Prototype.ps1 -Tests` builds them against the pinned backend; the
`desktop` tier, which opens visible windows, is run by hand with the shell
stopped.

Interactive keyboard/focus tests, native device-loss/capture fixtures,
desktop takeover, physical hotplug/DPI and long-running benchmarks are not
run by this gate. Neither are historical benchmark numbers or full
release-ZIP tamper/installation matrices claimed. Production smoke and the
[live checklist](../docs/LIVE-CHECKLIST.md) remain separate requirements.
