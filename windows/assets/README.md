# Preview fonts

These are unmodified upstream fonts, loaded only in the prototype process.
They are not installed into Windows.

| Font | Source revision and path | SHA-256 | License |
| --- | --- | --- | --- |
| Material Symbols Rounded | `google/material-design-icons` at `10ecc14790612ca8fd164e3f4ffe9c16fc50d5b7`, `variablefont/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf` | `7e74e36533ccee12c2b81e75bfcf3ccf123d3bb7e7e46d65d94445f23db0c97c` | [Apache 2.0](material-symbols-rounded/LICENSE) |
| Rubik | `google/fonts` at `e7db6ca603fd4862010383ff17ffd6cc4ffac1c0`, `ofl/rubik/Rubik[wght].ttf` | `1b3a7437ba2af80e465e773ed60c5036d1ba6ace492d89046dbcf18fb31e4e88` | [SIL OFL 1.1](rubik/OFL.txt) |

The original body font and its license remain in `assets/google-sans-flex`.
The full symbols font retains ligatures and variable axes used by Caelestia's
original `MaterialIcon.qml`.

The Windows stage also bundles these unmodified files from
[Nerd Fonts v3.4.0](https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.4.0):

| Font | Release archive | License |
| --- | --- | --- |
| Symbols Nerd Font Mono | `NerdFontsSymbolsOnly.zip`, `SymbolsNerdFontMono-Regular.ttf` | [MIT](nerd-font-symbols/LICENSE) |
| CaskaydiaCove NF (CaskaydiaCove Nerd Font) | `CascadiaCode.zip`, Regular, Bold, Italic and BoldItalic faces; Cascadia Code 2407.24 | [SIL OFL 1.1](caskaydia-cove/LICENSE) |

Exact archive URLs, release version, and SHA-256 hashes of both archives and
every vendored font/license are in [`sources.lock.json`](../sources.lock.json).
Staging checks these hashes and copies only the pinned files. Downloads happen
at development time; startup and staging use the checked-in files.
`WindowsFonts.qml` loads them into each prototype process. The Windows plugin
explicitly registers Symbols Nerd Font Mono for Qt's Common-script fallback,
covering both U+F444 and U+F0BAF while preserving Rubik workspace text and the
original CaskaydiaCove NF mono tokens. No font is installed into Windows.
