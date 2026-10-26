# Release documentation and notice packaging

Packaging-only validation on Windows 11 build 26300, using native Windows
PowerShell 5.1 and Qt 6.11.2. See [result.json](result.json) for source
revisions, tested file hashes, the existing build's provenance, exact paths
and limitations; [matrix.csv](matrix.csv) lists individual outcomes.

The documentation/package changes are in the commit containing this archive,
based on `9b732a3090914cf3e3a94b25e2366af2d18370bf`. Backend
`13b2d0930f798e7a0c006258a3a68824e300b2d6` and M3Shapes
`32ad9ce328bb77ed349b40a3be10ee9ea610b8ab` match the unchanged pins.
The test used an existing integration build, recorded as dirty source
`3482604c224f024b5f1c793d195f84fbbce3bb95`; this run did not rebuild it.
The installer staged this checkout's QML but the shell was never launched.

## Commands and observations

```powershell
powershell -NoProfile -File windows/scripts/Test-InstallLicenses.ps1 `
    -BuildRoot C:/Users/Ermin/.t3/worktrees/caelestia-windows/t3-488b52f1/windows/.local/build `
    -QtPrefix C:/Users/Ermin/AppData/Local/caelestia-dev/Qt/6.11.2/msvc2022_64
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
git diff --check
```

The temporary-prefix test passed installation, update and uninstall. It
compared notice bytes for the root license, notices index, source pins,
m3shapes, backend GPL/LGPL, Material Color Utilities, VirtualDesktop, all
current font notices and supplemental Nerd Fonts notices. It also compared
Qt's supplied license files and SBOMs and the packaged GPL/LGPL texts.
The temporary profile's marker survived install/update/uninstall, the
prefix including `licenses/` disappeared, the prefix-specific shortcut was
removed, and no autostart entry remained. The harness then removed its own
temporary test directory. See [install-test.log](install-test.log).

`windeployqt` warned about missing `translations/catalogs.json`; the existing
installer explicitly excludes translations. Both deployments returned zero.
Qt's aqt prefix contains SBOMs and a few component license files but no
top-level `licenses/` directory. Standard GPL/LGPL texts were included.
The complete Qt third-party redistribution audit remains a release gate.

All three new/changed PowerShell scripts parsed without errors using
`System.Management.Automation.Language.Parser.ParseFile`. `git diff --check`
passed. The [environment report](environment.json) confirms pin agreement
but reports that the ordinary process PATH lacks the compiler, CMake, Ninja
and Qt tools. That prerequisite result is separate from the packaging pass,
which used explicit Qt/build paths and the existing Visual Studio CRT.

No screenshots were produced because the test did not launch a UI. Runtime
acceptance, live desktop takeover, autostart, Python runtime provisioning,
clean-user-profile installation, rollback and purge were not tested here.
The release checklist retains those gates. No repository visibility,
workflows or remote repository contents were changed.
