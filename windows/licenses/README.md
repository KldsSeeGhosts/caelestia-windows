# Supplemental license texts

These unmodified texts cover the release's Nerd Fonts integration even when
the font assets have not yet been merged into a checkout:

- `fonts/caskaydia-cove/LICENSE`: Microsoft Cascadia Code SIL OFL 1.1,
  from `CascadiaCode.zip` in
  [Nerd Fonts v3.4.0](https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.4.0).
- `fonts/nerd-font-symbols/LICENSE`: Ryan L McIntyre's MIT license,
  from `NerdFontsSymbolsOnly.zip` in the same release.

Copies match the font integration's vendored license files. The installer
copies this directory into `licenses/`, then copies actual font notices from
`assets/` and `windows/assets/` so a bundled font's own notices take precedence.
No font binaries are added here.

See the root `THIRD-PARTY-NOTICES.md` for all projects and notice locations.
