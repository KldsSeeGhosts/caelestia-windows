# Repository ownership and protection

This document records ownership and the active branch and tag protection
settings for both repositories. The maintainer checked these settings against
the GitHub API on 2026-11-08. The ruleset IDs below are the evidence.

## Ownership

The current maintainer account is
[@KldsSeeGhosts](https://github.com/KldsSeeGhosts), the account used by this
public repository. The repository has one named maintainer; no team or alternate
owner is inferred. [`.github/CODEOWNERS`](../../.github/CODEOWNERS) routes
review for these sensitive areas. A CODEOWNERS match does not itself require an
approval.

| Area | Paths | Owner |
| --- | --- | --- |
| Workflow and CI | `.github/workflows/**`, `windows/ci/**`, `windows/cmake/**` | `@KldsSeeGhosts` |
| Build and release assembly | `windows/scripts/Build-Prototype.ps1`, `windows/scripts/Test-Validation.ps1`, `windows/scripts/Test-Smoke.ps1`, `windows/scripts/New-CaelestiaRelease.ps1` | `@KldsSeeGhosts` |
| Installer and supervisor | `windows/scripts/Install-Caelestia*.ps1`, `Caelestia-InstallCommon.ps1`, `Install-SchemeRuntime.ps1`, `Uninstall-Caelestia.ps1`, `Manage-Caelestia.ps1`, `Start-Caelestia*.ps1`, `Start-DesktopShell.ps1`, `Watch-DesktopShell.ps1`, `Restore-Desktop.ps1`, `DesktopTakeover.cs` | `@KldsSeeGhosts` |
| Native Windows platform | `plugin/src/Caelestia/Windows/**`, `windows/scripts/NativeAudioSnapshot.cs`, pinned native sources under `windows/deps/**` | `@KldsSeeGhosts` |
| Dependency pins | `.gitmodules`, `windows/sources.lock.json`, `windows/deps/**` | `@KldsSeeGhosts` |

The owner patterns are intentionally explicit for the sensitive paths above.
Update them when an owned path moves. Do not add a fictional team or email
alias.

## Active rulesets

| Repository | Ruleset | ID | Rules |
| --- | --- | --- | --- |
| `caelestia-windows` | `main: pull request and Windows validation` | 26789538 | Pull request with zero approvals, required check `Windows validation`, no force pushes, no deletion |
| `caelestia-quickshell-windows` | `main: pull request and backend Windows gate` | 26789537 | Pull request with zero approvals, required check `Build all fixtures, run portable tier`, no force pushes, no deletion |
| `caelestia-windows` | `release tags v*: immutable once created` | 26790836 | No update, no deletion, no non-fast-forward push |
| `caelestia-quickshell-windows` | `release tags v*: immutable once created` | 26790837 | No update, no deletion, no non-fast-forward push |

Both tag rulesets match `v*` tags. They have no creation rule. GitHub rejects an
Actions bypass on personal-account repositories, and the development publisher
must create tags. Tag creation therefore stays open to the maintainer release
process.

Secret scanning and push protection are on in both repositories.

## Required checks

The shell workflow is `Windows build` and defines these job names:

- `Change scope` (immutable dispatch guards and native-change classifier)
- `Fast regressions (${{ matrix.shard }}/3)` expands to
  `Fast regressions (1/3)`, `Fast regressions (2/3)`, and `Fast regressions (3/3)`
- `Installer and colour regressions (${{ matrix.shard }}/2)` expands to
  `Installer and colour regressions (1/2)` and `Installer and colour regressions (2/2)`
- `Verified native reuse and offscreen regressions` (PR-only, verified native inputs from the newest validated main ancestor)
- `Backend fixtures and portable tier` (conditional on the native-change classifier)
- `Native build and offscreen regressions` (conditional on the native-change classifier)
- `Exact-pair receipt` (joins successful fixture and integration evidence)
- `Windows validation` (the always-run aggregate)
- `Prepare unsigned corresponding sources` (main-only, read-only preparation
  beside validation; candidate assembly requires it, native validation does not)
- `Assemble exact-tested release candidate` (native main pushes, unsigned early
  assembly after scope and sources; contents-read and actions-read permissions;
  not a required validation prerequisite)
- `Nexus development publication` (main-only, after assembly, pair and validation;
  credential-free sealing precedes signing; inert unless the
  owner enables its variable and protected environment)

Required shell gate: `Windows validation`.

For shell pull requests, the required gate is `Windows validation`. Scope, the
three fast shards and both installer/colour shards start concurrently.
Scope unlocks the applicable native jobs.
The fixtures job owns first-party capture Rust regressions and their separate
`capture-rust-*` artifact. A capture failure fails fixtures and the required
`Windows validation` aggregate. The native build does not wait for capture tests.
The aggregate waits for scope, the fast and installer/colour jobs and requires
fixtures, native integration and the receipt join to succeed when
the classifier says it is required. For a documentation-only change, the
classifier deliberately marks native validation not required and the aggregate
expects all three native jobs and reuse to be skipped. For eligible QML/JS/assets
PRs, the aggregate requires successful verified reuse and all three native jobs
skipped, or explicit fallback with successful full fixtures/build/pair gates.
Reuse does not claim pair or release eligibility. All non-PR events build fully.
The ruleset requires only `Windows validation`, not a conditional native job,
because that would leave documentation-only changes pending.

The pinned backend workflow is `Windows fixtures`; its current job name is
`Build all fixtures, run portable tier`.

Required backend gate: `Build all fixtures, run portable tier`.

That job builds the fixture targets and runs the portable tier; it does not
claim a physical desktop test.

The exact-SHA shell integration gate is separate work. Do not invent a check
name for it or treat either repository's producer check as proof that an
arbitrary shell/backend candidate pair was qualified.

## Branch, tag, and recovery

The active integration policy for each repository is:

1. Merge ordinary changes through a pull request to `main`. The required check
   must pass. A failed, cancelled, or missing required check must block an
   ordinary merge. The ruleset requires zero approvals.
2. Do not force-push `main` or delete it. The ruleset refuses both.
3. Do not update or delete a release tag matching `v*`. The ruleset refuses
   update, deletion and non-fast-forward. Tag creation has no rule, as
   described above.
4. Do not require two reviewers for a solo-maintainer repository. The named
   owner remains responsible for review and merge.

The repository admin role is the only bypass actor. On `main`, the bypass works
only through a pull request. On tags, the bypass is always available. Use it
only for a genuine recovery from a broken rule or an urgent incident. Do not
grant bypass to a team, application, or general contributor set. Record the
reason in a pull request or issue and run the normal checks afterward where
possible. Bypass is an exception path, not the routine merge route. The
administrator is [@KldsSeeGhosts](https://github.com/KldsSeeGhosts).

Recheck these settings against current repository state before changing any rule
or bypass. Record the new evidence here.

## Reporting and bug reports

Use [`SECURITY.md`](../../SECURITY.md) for vulnerability-reporting instructions.
Do not put vulnerability details in public issues or pull requests. For ordinary
bugs, use the detailed
[sanitized Windows bug-report form](../../.github/ISSUE_TEMPLATE/bug_report.yml).
Do not include raw user profiles, secrets, private notification/clipboard
content, or unredacted personal paths. Screenshots are optional and never
required.
