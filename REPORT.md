# Windows Nerd font implementation

Implemented on `t3/fonts`, based on `origin/t3/integration` at `4697ffa8`.
Implementation commits: `f88291b9`, `24aa63a2`. No pushes, PRs, Linear work,
subagents, system font installation or administrator operations.

## Change

- Vendored unmodified Symbols Nerd Font Mono and four CaskaydiaCove NF faces
  from Nerd Fonts v3.4.0, with MIT and SIL OFL licenses. Exact release archive
  URLs and SHA-256 hashes of archives, fonts and licenses are recorded in
  `windows/sources.lock.json`. Git attributes preserve their release bytes.
- Every Windows shell prototype stages and loads the local font files.
  Staging verifies pinned hashes; no font is downloaded at runtime.
- A Windows-only `WindowsFontFallback` singleton returns a QFont with ordered
  families `[configured workspace primary, Symbols Nerd Font Mono]`, retaining
  other font attributes. Staging adapts the one original workspace font binding.
  Upstream module/config defaults remain unchanged. Qt 6.11 does not expose
  `font.families` in QML, so this small C++ bridge supplies the actual list.
- The bundled CaskaydiaCove NF family matches the existing mono tokens/builders.
  A PUA scan found U+F444 and U+F0BAF only in workspace config defaults.
  Mono consumers are StatusIcons, WirelessPassword, Record, NotifDock and Fetch.
  Those components need no per-component font edits; lock/recorder stay outside
  the current runtime scope. Global font fallback is unchanged.

## Validation

Only `caelestia-windowsplugin` was rebuilt, using Qt 6.11.2 and clang-cl 20.1.8,
inside private `windows/.local/font-build`. The supplied build's backend and
other modules were copied/reused unchanged. Combined `-Smoke` passed with exit
0, no warning/error diagnostics, at native 150% on MAG321UX OLED. The smoke now
checks the new FontLoaders and logs loaded/unchanged token families.

The inspected capture shows the active Pac-Man glyph and four inactive dots,
with no tofu boxes and normal body typography. An application-only probe uses
a temporary unique font family absent from Windows' font database, then proves
the explicit ordered families select Rubik for A and the application-only font
for both PUA glyphs, with nonzero glyph indices. This avoids falsely relying on
the Nerd fonts found registered in Windows during this session. This agent did
not install, remove or change those registrations. A clean-profile shell run
was not performed.

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot "$PWD\windows\.local\font-build" -Combined -Smoke
```

[Evidence and reproduction details](windows/validation/2026-10-26-nerd-fonts/README.md),
[result](windows/validation/2026-10-26-nerd-fonts/result.json),
[capture](windows/validation/2026-10-26-nerd-fonts/workspace-glyphs.png).

The required environment prerequisite check was run. It reports tools absent
from the ordinary PATH and the pre-existing submodule checkout mismatch:
lock/gitlink `cc2cf04d`, checked-out `525786fc`. The mismatch was preserved and
excluded from commits. The supplied binary's build record identifies backend
`cc2cf04d`; the smoke result's backendRevision field reads the source checkout.
This is quick font validation, not a full rebuild, release gate or live-service
acceptance run. Rebuild/install the updated Windows plugin before using the
new staged workspace binding with another build tree.