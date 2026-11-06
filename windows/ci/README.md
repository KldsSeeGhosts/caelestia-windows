# Public Windows CI preparation

`windows-build.yml.template` is deliberately inert, outside
`.github/workflows`. Preparing or statically checking it does not establish
hosted-build acceptance. The active workflow, when enabled after the source
prerequisites below, is `.github/workflows/windows-build.yml`.

## Public-source prerequisites

The active [Windows workflow](../../.github/workflows/windows-build.yml) was
enabled after maintainer publication authorization and an anonymous recursive
source check. Keep the shell, backend, and **all required recursive
submodule repositories and exact pinned refs** anonymously accessible. Check
the gitlinks, `.gitmodules`, and `windows/sources.lock.json`, including Glazier
and M3Shapes. Do not work around private dependencies with a PAT, deploy key,
or injected authentication secret.

The template remains a non-executing reference; changes to it do not update the
active workflow automatically. The active file runs one `windows-latest` job on pushes to `main`, pull
requests, and manual dispatch. It has read-only contents permission, no
`pull_request_target`, no persisted checkout credentials, and no injected
tokens or authentication secrets for untrusted PR code. The official Actions
use their normal scoped runner credentials, not publication credentials.

## What the job does

Preparation follows [NATIVE-BUILD.md](../NATIVE-BUILD.md): Python 3.12,
CMake 4.4.4, Ninja 1.13.2, aqtinstall revision
`076e1659807d0b362a3ed684d54c2e9c775eb9c7`, Qt 6.11.2
`win64_msvc2022_64`, LLVM 20.1.8, and CLI11 v2.5.0. Qt includes
`qtshadertools qtimageformats` and base archives
`qtbase qtdeclarative qtsvg qttools`. It intentionally omits `qttranslations`
as documented there. LLVM and CLI11 archive SHA-256 checks run on both
downloads and cache restores, before extraction. aqt's archive checksum
verification stays enabled; restored Qt tooling is checked for version and
required files.

Glazier's pinned `Cargo.toml` declares Rust edition 2024, not an exact compiler
version or `rust-toolchain` file. Its README requires Windows MSVC Rust. The
job selects the hosted runner's `stable-x86_64-pc-windows-msvc` toolchain
through a job-local environment variable and records `rustc`/`cargo`
versions. It does not invent a Rust version pin, install a new toolchain, or
skip Glazier. The existing build uses Cargo's `--locked` dependency graph.

The only gates are the existing `Build-Prototype.ps1` production build into
`C:\b-public`, then `Test-Smoke.ps1` with its isolated offscreen profile.
Preparation stays inline. The build discovers Visual Studio and its SDK and
enters the compiler environment itself. No machine-wide PATH/settings changes,
extra suites, benchmark tooling, live desktop/input/DPI/hotplug/hardware
checks, installation, signing, or publication are included.

The versioned exact-match tooling cache contains Qt, verified LLVM/CLI11
download archives, and pip's download/wheel cache. Python tooling is installed
fresh from those cached downloads. Only trusted `main` runs save this cache;
PRs may restore it. There are no compiler, Cargo target, build-tree, staged
shell, or product-output caches mixing untrusted payloads. Change the cache
schema key when preparation or Qt's selected components change.

Superseded runs are cancelled and the job has a 60-minute limit. On failure,
only preparation/build logs, smoke's redacted failure summary, and build
records outside the source checkout are uploaded, with three-day retention.
Raw smoke capture logs, profiles, and staged payloads are not uploaded. These
diagnostics are not release artifacts.

## Still pending

After authorization, record actual cold and cached hosted runs, their heads,
outcomes, and timings in the release record. Neither run is established by
preparing this source template.
Local static validation is not a substitute for that acceptance or for live
desktop validation.
