# Versioning

Published build and display versions are plain `MAJOR.MINOR.PATCH`, without
prerelease identifiers or build metadata. General client parsing and precedence
still follow SemVer 2.0.0 and accept historical versions.

## Immutable allocation

`windows/release/version.json` contains the reviewed base, initially `0.3.0`.
It is an anchor, not a file to bump for every release. The anchor commit is
the latest first-parent commit where that base value changed, found with
`git log` on the file and comparison against each candidate's first parent.
The switch's own merge commit therefore receives `0.3.0`. Editing other fields
does not move the anchor. A later reviewed base change starts a new anchor.
Only the owner declares 1.0 after dependable operation and release review.

`windows/ci/history_version.py` folds every later first-parent commit in order.
For GitHub merge commits, it reads the PR title recorded after
`Merge pull request #N from ...`. Topic-branch commits do not count separately.
It never reads labels, releases, channel pointers or run numbers to allocate
a version. Direct non-merge commits always consume a patch.

| Recorded PR title or merge message | Bump |
| --- | --- |
| `feat: ...` or `feat(scope): ...` | MINOR, reset PATCH |
| `feat!: ...`, `fix(scope)!: ...`, or a `BREAKING CHANGE:` line | MAJOR, reset MINOR and PATCH. Before 1.0, MINOR and reset PATCH |
| `fix: ...`, `perf: ...`, `refactor: ...`, any other or missing prefix | PATCH |

There is no threshold rollover. For example, `0.3.99` plus a patch is
`0.3.100`. All computed components must fit native Windows VERSIONINFO,
0 through 65535. Overflow fails, never wraps. Every compatibility break needs
a changelog migration and rollback compatibility note.

| First-parent history | Computed version | Publication outcome |
| --- | --- | --- |
| Switch anchor | `0.3.0` | Initial plain build |
| C1, `fix: ...` | `0.3.1` | Can publish before C2 |
| C2, `fix: ...` | `0.3.2` | Distinct even if C1 has not published |
| C3, `docs: ...` | `0.3.3` | May not publish, still consumes version |
| C4, `feat: ...` | `0.4.0` | PATCH resets |
| Re-run C2 at any time | `0.3.2` | Never reallocates to another version |

Failed builds and docs/CI-only commits leave gaps. Versions are never reused.
CI checks out complete history. Shallow history fails closed. Local builds on
topic branches use the same fold on their own first-parent history, but only
exact-main push evidence can authorize a channel publication.

The existing `nexus-publication` concurrency group serializes publication.
A version at or below the authenticated channel highwater is refused before
release writes. Source ancestry and immutable asset/tag checks remain gates.
Thus C1 finishing after C2 cannot publish out of order. An Actions re-run keeps
the version but has new run/attempt provenance and must rerun all producer gates.
It cannot replace an existing version's bytes or adopt another attempt's
candidate. Same-attempt partial draft recovery retains its existing byte checks.

## Titles and promotions

PR titles must start with `feat`, `fix`, `perf`, `refactor`, `docs`, `test`,
`build`, `ci`, `chore`, `style` or `revert`, followed by an optional scope,
optional `!`, then `: description`. The existing Change scope job checks this
on PR creation, updates and title edits. It adds no new required check.
Review the final title before merging. Editing a PR title after merge cannot
alter the title stored in the merge commit. Labels have no versioning role.

Preview and stable promote identical tested development artifacts. They do not
rewrite native VERSIONINFO, manifests or build identity. For build `0.3.0`,
development uses `v0.3.0-development` and preview uses `v0.3.0-preview`.
Stable requires tested bytes at least `1.0.0` and uses `v1.0.0`.
The explicit promotion alias must equal the build version. All these tags
match the active immutable `v*` tag ruleset. Historical tags stay unchanged.
Stable clients never fall back to development. Channel switches cannot
authorize a network downgrade. Pointer sequence remains separate from version.

## SemVer migration bridge

PR #140 is the bridge. It still publishes legacy
`CORE-dev.EPOCH.RUN.ATTEMPT` builds, but its updater and Nexus page accept both
legacy versions and plain SemVer. This switch must merge only after a bridge
build has been published and the owner has installed it.

Every `0.2.0-dev.*` build precedes `0.3.0`, regardless of epoch, run or attempt
size. Older clients such as `0.2.0-dev.1.283.1` reject plain versions as
`bad-metadata` and must install the bridge first. Rolling back to a pre-bridge
payload restores that old client's format limit. Signature, channel-role,
replay and downgrade checks remain unchanged. Never clear trust or highwater
state to bypass them. A source revision, release directory or JSON schema
number is not an app version. Local payloads are not channel releases.
