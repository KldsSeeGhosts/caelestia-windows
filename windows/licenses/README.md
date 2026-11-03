# Font license sources

Each bundled font's vendored notice is the single source of truth:

- `windows/assets/caskaydia-cove/LICENSE` and
  `windows/assets/nerd-font-symbols/LICENSE` are copied into `licenses/fonts/`
  by the installer. Google Sans Flex comes from `assets/`; Rubik and Material
  Symbols Rounded come from `windows/assets/`.

This directory no longer keeps duplicate font texts. The installer copies this
README into the payload's `licenses/` directory and then copies the actual font
notices from `assets/` and `windows/assets/`.

See the root `THIRD-PARTY-NOTICES.md` for all projects and notice locations.
