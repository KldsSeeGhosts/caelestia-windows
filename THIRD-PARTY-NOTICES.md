# Third-party notices

Caelestia for Windows retains the licenses and copyright notices of its
dependencies. This index does not replace their license texts. Copyright
holders below identify the projects; individual source files and bundled
notices retain more detailed authorship.

Paths under `licenses/` are relative to the installation prefix. Repository
paths are relative to this checkout. Exact source revisions are recorded in
[`windows/sources.lock.json`](windows/sources.lock.json) and the submodule
gitlinks. The installed copy of that manifest is `licenses/sources.lock.json`.
This index also covers the fonts and scheme integration supplied by the
release integration branches; a component listed here need not be present in
an earlier checkout. Check the actual payload and its recorded revisions.

## Interface and colour generation

| Component and source | Copyright holders | License | License text in repository or runtime | Installed notice |
| --- | --- | --- | --- | --- |
| [Caelestia Shell](https://github.com/caelestia-dots/shell) | soramanew and Caelestia contributors | GPL-3.0 | `LICENSE` | `licenses/LICENSE`, also `licenses/Caelestia-LICENSE` |
| [m3shapes](https://github.com/soramanew/m3shapes) | soramanew and contributors | Apache-2.0 | `windows/deps/m3shapes/LICENSE` | `licenses/M3Shapes-LICENSE` |
| [Caelestia CLI](https://github.com/caelestia-dots/cli) | soramanew and Caelestia CLI contributors | GPL-3.0 | Runtime package metadata under the profile's `scheme/venv/Lib/site-packages/caelestia*.dist-info/` | The package's `LICENSE` or `licenses/` metadata in that virtual environment; GPL text also at `licenses/GPL-3.0.txt` |
| [materialyoucolor](https://github.com/T-Dynamos/materialyoucolor-python) | Copyright (c) 2023 Ansh Dadwal (T-Dynamos) and contributors | MIT | Runtime package metadata under `scheme/venv/Lib/site-packages/materialyoucolor*.dist-info/` | The package's `LICENSE` or `licenses/` metadata in that virtual environment |
| [Pillow](https://github.com/python-pillow/Pillow) | Secret Labs AB; Fredrik Lundh; Alex Clark and Pillow contributors | HPND (PIL/Pillow license) | Runtime package metadata under `scheme/venv/Lib/site-packages/pillow*.dist-info/` | The package's `LICENSE` or `licenses/` metadata in that virtual environment, including its bundled-library notices |
| [Python](https://www.python.org/) | Python Software Foundation and earlier Python copyright holders | PSF-2.0 and historical Python licenses | Prerequisite, not vendored; `LICENSE.txt` in the user's Python installation | Retained in the prerequisite Python installation; virtual environments use that installation |

Python is required for colour generation. Caelestia CLI, materialyoucolor and
Pillow are provisioned at runtime into a profile-local virtual environment,
not bundled by the shell installer. Keep their distribution metadata and
license files with that environment. An ordinary uninstall preserves the
profile, including these notices; `-Purge` removes it.

## Clipboard overlay

The clipboard picker's presentation and display-row model are adapted from
Omarchy's `quattro` clipboard, via the user's Linux Caelestia overlay. Windows
specifics (native clipboard history, paste dispatch, the panel host and image
previews) replace Omarchy's `wl-paste` helpers and shell scripts.

| Component and source | Copyright holders | License | License text in repository | Installed notice |
| --- | --- | --- | --- | --- |
| [Omarchy](https://github.com/omacom/omarchy) clipboard | David Heinemeier Hansson | MIT | `windows/services/clipboard/upstream/LICENSE-MIT.txt` | `licenses/Clipboard-Overlay-MIT.txt` |

## Windows backend and runtime

| Component and source | Copyright holders | License | License text in repository or build prerequisite | Installed notice |
| --- | --- | --- | --- | --- |
| [Quickshell](https://git.outfoxxed.me/quickshell/quickshell) | outfoxxed and Quickshell contributors | LGPL-3.0 | `windows/deps/quickshell/LICENSE` and `LICENSE-GPL` | `licenses/Quickshell-LICENSE`, `licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt` |
| [Windows Quickshell](https://github.com/nunreasonable/quickshell) | nunreasonable and Windows Quickshell contributors, with upstream Quickshell copyright retained | LGPL-3.0 | Same backend license files | Same backend license texts |
| [Caelestia Windows backend fork](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows) | Ermin Zeherovic (KldsSeeGhosts) and contributors, with upstream copyright retained | LGPL-3.0 | Same backend license files | Same backend license texts |
| [Material Color Utilities](https://github.com/material-foundation/material-color-utilities) (vendored in the backend) | Google LLC | Apache-2.0 | `windows/deps/quickshell/src/windows/third_party/material_color/LICENSE` | `licenses/MaterialColor-LICENSE`, also `licenses/Quickshell-third-party/material_color/LICENSE` |
| [VirtualDesktop](https://github.com/MScholtes/VirtualDesktop) (adapted desktop COM interface definitions) | Copyright (c) 2017 Markus Scholtes | MIT | `windows/deps/quickshell/src/windows/third_party/virtual_desktop/LICENSE`; provenance in the adjacent `README.md` | `licenses/Quickshell-third-party/virtual_desktop/LICENSE` |
| [Qt 6](https://www.qt.io/development/qt-framework) | The Qt Company Ltd. and Qt contributors; bundled third parties retain their own copyright | LGPL-3.0 for the deployed Qt libraries, plus applicable module and third-party licenses | License files supplied by `QtPrefix` (`licenses/`, `LICENSES/`, or component license files); some aqt archives provide `sbom/` instead. Standard GPL/LGPL texts are also in the backend license files above | `licenses/Qt/` holds supplied license files and GPL/LGPL texts; `licenses/Qt-sbom/` holds supplied SBOMs |
| [Microsoft Visual C++ runtime](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files) | Microsoft Corporation | Microsoft Visual Studio redistribution terms, proprietary | The Visual Studio installation's license terms and redistributable list; supplied via `VCRuntimeRoot`, not vendored here | App-local CRT DLLs; redistribution must follow the supplying Visual Studio license |

Qt is dynamically linked. The installer uses the build's Qt prefix and
`windeployqt` to deploy its runtime. SBOMs record component provenance and
license identifiers; they are not a substitute for applicable license texts.
Before distributing a release, audit deployed Qt modules and their embedded
third parties against those records and include any additional required texts.

[ii-windows](https://github.com/nunreasonable/ii-windows), copyright
nunreasonable and contributors, is GPL-3.0. It was a packaging reference only:
no code was copied into this port, and it is not installed. Its license is in
the [reference project's LICENSE](https://github.com/nunreasonable/ii-windows/blob/main/LICENSE),
not in this payload.

## Fonts

Fonts are loaded into the shell process, not installed system-wide.

| Component and source | Copyright holders | License | License text in repository | Installed notice |
| --- | --- | --- | --- | --- |
| [Google Sans Flex](https://github.com/googlefonts/googlesans-flex) | The Google Sans Flex Project Authors | SIL OFL 1.1 | `assets/google-sans-flex/LICENSE` | `licenses/fonts/google-sans-flex/LICENSE` |
| [Rubik](https://github.com/googlefonts/rubik) | Copyright 2015 The Rubik Project Authors; Hubert and Fischer, Meir Sadan, Cyreal and contributors | SIL OFL 1.1 | `windows/assets/rubik/OFL.txt` | `licenses/fonts/rubik/OFL.txt` |
| [Material Symbols Rounded](https://github.com/google/material-design-icons) | Google LLC | Apache-2.0 | `windows/assets/material-symbols-rounded/LICENSE` | `licenses/fonts/material-symbols-rounded/LICENSE` |
| [Cascadia Code](https://github.com/microsoft/cascadia-code), patched as [CaskaydiaCove Nerd Font](https://github.com/ryanoasis/nerd-fonts) | Copyright (c) 2019 - Present, Microsoft Corporation; Nerd Fonts contributors | SIL OFL 1.1 | `windows/licenses/fonts/caskaydia-cove/LICENSE`; font integration also supplies `windows/assets/caskaydia-cove/LICENSE` | `licenses/fonts/caskaydia-cove/LICENSE` |
| [Nerd Fonts Symbols](https://github.com/ryanoasis/nerd-fonts) | Copyright (c) 2014 Ryan L McIntyre and contributors | MIT | `windows/licenses/fonts/nerd-font-symbols/LICENSE`; font integration also supplies `windows/assets/nerd-font-symbols/LICENSE` | `licenses/fonts/nerd-font-symbols/LICENSE` |

The installer copies font license and notice files from both `assets/` and
`windows/assets/`, including new fonts introduced by integration updates.
Supplemental font texts and their provenance are in
[`windows/licenses/README.md`](windows/licenses/README.md).

## Screenshot and recording tool

Glazier is the shell's bundled screenshot and recording tool. It is built from
the pinned source in `windows/deps/glazier` and installed beside `qs.exe` in the
versioned payload.

| Component and source | Copyright holders | License | License text in repository | Installed notice |
| --- | --- | --- | --- | --- |
| [Glazier](https://github.com/KldsSeeGhosts/glazier) | Ermin Zeherovic (KldsSeeGhosts) and contributors; the annotation editor is ported from the Noctalia Screen Toolkit by ycf-anon and Tabler Icons by Tabler | MIT as declared in `windows/deps/glazier/Cargo.toml`; the pinned revision does not yet carry a `LICENSE` file | `windows/deps/glazier/Cargo.toml` and `windows/deps/glazier/THIRD_PARTY_NOTICES.md` | `licenses/Glazier-THIRD_PARTY_NOTICES.md` |

The pinned Glazier revision carries its upstream third-party notices but not a
top-level `LICENSE` file. Publishing the tool and adding that licence is a
public-release gate tracked in #97; until then the installer ships the notices
present in the pin and this index states the licence declared by the package.

## Port authorship

The Windows service adapters, shell entries, build and packaging tools,
documentation, focus guard, WASAPI visualizer, scheme bridge and Wallpaper
Engine integration are the work of the Windows port maintainer and
contributors, under the repository's GPL-3.0 license (`LICENSE`). Backend
changes live in the separate LGPL-3.0 backend fork. Wallpaper Engine is an
external application by its respective authors, not bundled with this port.

The port was built with substantial AI assistance: Claude orchestrated the
work, with GPT, GLM, DeepSeek and Gemini agents implementing parts of it.
The maintainer directed and reviewed the work. Upstream projects retain their
own authorship and copyright.
