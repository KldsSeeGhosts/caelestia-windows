# Repository ownership and protection plan

This document records intended review and merge policy. It is not evidence that
GitHub branch protection, repository rulesets, or tag protection have been
configured. Branch protection and tag settings are not claimed as active or
verified by this document.

## Ownership

The current maintainer account is
[@KldsSeeGhosts](https://github.com/KldsSeeGhosts), the account used by this
public repository. The repository currently has one named maintainer; no team
or alternate owner is inferred. [`.github/CODEOWNERS`](../../.github/CODEOWNERS)
routes review for these sensitive areas. A CODEOWNERS match does not itself
require an approval.

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

## Required-check plan

The following are the exact workflow and job labels in the checked-in source.
They are source facts, not a readout of GitHub's current required-check
settings. Use the exact contexts shown by the repository's required-check
selector when settings access is available; do not guess or rename a context.

The shell workflow is `Windows build` and currently defines these job names:

- `Fast regressions`
- `Installer and colour regressions`
- `Native build and offscreen regressions` (conditional on the native-change classifier)
- `Windows validation` (the always-run aggregate)
- `Nexus development publication` (main-only, after validation, inert unless the
  owner enables its variable and protected environment)

Required shell gate: `Windows validation`.

For shell pull requests, the planned required gate is `Windows validation`.
It waits for the fast and installer/colour jobs and checks the native job when
the classifier says it is required. For a documentation-only change, the
classifier deliberately marks native validation not required and the aggregate
expects the native job to be skipped. Do not require the conditional native job
by itself, because that would leave documentation-only changes pending.

The pinned backend workflow is `Windows fixtures`; its current job name is
`Build all fixtures, run portable tier`.

Required backend gate: `Build all fixtures, run portable tier`.

That job builds the fixture targets and runs the portable tier; it does not
claim a physical desktop test.

The exact-SHA shell integration gate is separate work. Do not invent a check
name for it or treat either repository's producer check as proof that an
arbitrary shell/backend candidate pair was qualified.

## Branch, tag, and recovery plan

For each repository, the intended integration policy is:

1. Merge ordinary changes through pull requests to `main`, with the repository's
   required check passing. A failed, cancelled, or missing required check must
   block an ordinary merge.
2. Prevent force pushes to and deletion of `main`.
3. Protect release tags matching `v*` from update and deletion; limit tag
   creation to the maintainer/release process.
4. Do not require two reviewers for a solo-maintainer repository. The named
   owner remains responsible for review and merge.

The only planned bypass actor is `@KldsSeeGhosts`, for a genuine recovery from a
broken rule or an urgent incident. Do not grant bypass to a team, application,
or general contributor set. Record the reason in a pull request or issue and
run the normal checks afterward where possible. Bypass is an exception path,
not the routine merge route.

These settings must be checked against current repository state before
configuration. This document does not claim that any rule or bypass has been
applied.

## Reporting and bug reports

Use [`SECURITY.md`](../../SECURITY.md) for vulnerability-reporting instructions.
Do not put vulnerability details in public issues or pull requests. For ordinary
bugs, use the detailed
[sanitized Windows bug-report form](../../.github/ISSUE_TEMPLATE/bug_report.yml).
Do not include raw user profiles, secrets, private notification/clipboard
content, or unredacted personal paths. Screenshots are optional and never
required.
