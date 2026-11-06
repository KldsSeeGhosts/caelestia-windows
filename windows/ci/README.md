# Public Windows CI

The active workflow is
[.github/workflows/windows-build.yml](../../.github/workflows/windows-build.yml).
The old `windows-build.yml.template` is an inert historical preparation
reference, not the active configuration.

## Gates and build scheduling

Every push to `main`, pull request and manual dispatch runs fast source,
documentation, PowerShell, JavaScript and quota-provider regressions first.
After those pass, two jobs can run independently:

- Installer/rollback tests and the real colour-worker tests use isolated,
  temporary profiles and pinned Python dependencies.
- The native job prepares the Windows tools, runs service contracts, builds
  the production payload and plugin tests once, then runs native CTest
  fixtures, shell fixtures and production smoke.

Only a narrow allowlist of documentation and issue-template changes skips the
native job. Unknown files, empty diffs, first pushes and manual dispatches
require a build. The path decision itself has regression tests. Installer and
fast checks still run for documentation changes. The final `Windows validation`
job fails if any applicable gate failed, was cancelled or was unexpectedly
skipped. No branch-protection settings are changed by this workflow.

[Test-Validation.ps1](../scripts/Test-Validation.ps1) is the shared local/CI
entry point. [Coverage and exclusions](../tests/README.md) distinguish
offscreen checks from live-desktop acceptance.

## Tooling and cache trust

The native toolchain remains Python 3.12, CMake 4.4.4, Ninja 1.13.2,
aqtinstall revision `076e1659807d0b362a3ed684d54c2e9c775eb9c7`,
Qt 6.11.2 `win64_msvc2022_64`, LLVM 20.1.8 and CLI11 2.5.0.
Qt includes `qtshadertools qtimageformats` and archives
`qtbase qtdeclarative qtsvg qttools`, not `qttranslations`.
The hosted stable MSVC Rust toolchain builds Glazier's locked dependency
graph; the job records the compiler version rather than inventing a Rust pin.

The versioned exact-match cache contains Qt, LLVM/CLI11 archives and extracted
trees, and pip's download cache. Warm runs avoid extracting LLVM and CLI11
again. Archive checksums still run after restore, and required tool files and
versions are checked before use. Python tooling is installed fresh. Only
trusted `main` runs save this cache; pull requests may restore it. There are
no native object, CMake build, Cargo target, staged-shell or installed-product
caches shared across trust boundaries. Change the cache schema key when the
tooling selection or extraction contract changes.

All Actions are commit-pinned. Permissions stay read-only; checkout does not
persist credentials. There is no `pull_request_target`, injected publication
secret, installation into a user's profile, signing or release publication.
The source and every pinned recursive dependency must remain anonymously
accessible. Never substitute private dependency credentials.

## Evidence and limits

Regression jobs upload only compact summaries containing test names, exit
codes, timings, source revision and dirty status, with three-day retention. Raw fixture
logs, profiles and provider data are not uploaded. Existing build-failure
diagnostics and the production smoke's redacted failure summary remain
available on failure.

Local passes establish only the exact tested working tree, native runner and
scenarios. They do not establish hosted acceptance of a workflow edit. Record
fresh cold and warm hosted runs after publication before claiming a CI
performance improvement. Hardware, input, DPI, hotplug, sleep/wake and
long-running desktop acceptance still require the
[live checklist](../docs/LIVE-CHECKLIST.md).
