# Nerd font smoke, 2026-10-26

Implementation: `24aa63a2` on `t3/fonts`, based on `4697ffa8`.
Qt 6.11.2 MSVC x64, clang-cl 20.1.8, native Windows at 150% on
MAG321UX OLED. This archive covers font loading and workspace rendering only.

## Build and launch

The supplied build at
`C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-325d7919\windows\.local\build`
was copied to this worktree's `windows/.local/font-build`. Only the
`caelestia-windowsplugin` target was rebuilt from this worktree, using CMake
Ninja Release, `CAELESTIA_PORTABLE_UI=ON`, `ENABLE_MODULES=plugin`, and Qt
`%LOCALAPPDATA%/caelestia-dev/Qt/6.11.2/msvc2022_64`. The Windows backing DLL,
plugin DLL, qmldir and qmltypes were copied into that private install tree.
The supplied backend and remaining Caelestia DLLs were reused unchanged.
`build.json` retains the original build metadata plus `windowsFontPlugin`
metadata; `build-windows-fonts.log` records the plugin build.

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot "$PWD\windows\.local\font-build" -Combined -Smoke
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

The prerequisite report is not a build result. It reports tools absent from
the ordinary PATH and a pre-existing backend checkout mismatch: gitlink/lock
`cc2cf04d`, checked-out submodule `525786fc`. That checkout was left untouched.
The reused binary's build record identifies backend `cc2cf04d`; the smoke
harness's `backendRevision` field reads the current source checkout instead.

## Font coverage and independent fallback probe

Nerd Fonts v3.4.0 release assets and every vendored font/license are pinned by
SHA-256 in `windows/sources.lock.json`. Staging verifies those bytes. Every
host loads Symbols Nerd Font Mono plus Regular/Bold/Italic/BoldItalic
CaskaydiaCove NF application faces. No runtime downloads, font installation,
registry edits, admin operation or system fallback changes are performed.

The literal/escaped PUA scan of `modules/` and config defaults found only
`barconfig.hpp`: U+F444 (label), U+F0BAF (occupiedLabel, activeLabel).
`Tokens.font.mono` consumers are WirelessPassword, StatusIcons, utilities
Record, lock NotifDock and lock Fetch. Bundled CaskaydiaCove NF matches the
original family name and carries the Nerd glyphs; tokens/builders are intact.
Lock/recorder are not newly enabled or claimed runtime validated here.

Qt 6.11 QML exposes `font.family`, not `font.families`. The Windows staging
adapter replaces only Workspace.qml's family binding with the Windows
helper's explicit QFont families `[configured primary, Symbols Nerd Font Mono]`.
Other font attributes and upstream source remain intact. No global
Common-script fallback is registered, because that experiment changed
ordinary shell typography and was rejected.

Windows Nerd fonts were already registered by the time the first smoke ran
(file creation timestamps around 01:44:57). This agent did not install them,
remove them or alter those registrations. Therefore the shell capture alone
cannot demonstrate a pristine profile. The focused probe renames a local
copy of Symbols to `AppOnly Nerd Font Mono`, asserts it is initially absent
from QFontDatabase, loads it as an application font, sets the explicit ordered
families, and lays out `A U+F444 U+F0BAF`. Qt reports Rubik for A and the unique
application-only font for both PUA glyphs, with nonzero glyph indices 3277 and
6507. See `application-fallback.log` and `application-fallback-probe.cpp`.
`prepare-application-font.py` reproduces the temporary family name; the altered
font is not archived or shipped. The probe links Qt6::Gui and receives the
AppOnly.ttf and Rubik.ttf absolute paths as argv[1] and argv[2].

## Results

See `result.json`, logs and `workspace-glyphs.png`. The capture was visually
inspected for an active Pac-Man glyph and four inactive dots, with no tofu
boxes. The smoke asserts all five new FontLoaders are Ready and records the
loaded families beside the unchanged mono and workspace tokens. All native
write gates remain off. This is a quick font smoke, not a shell release,
full DPI matrix, pristine-profile installation test or live service validation.