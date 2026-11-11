# Changelog

## [Unreleased]

### Added

- Reviewed 0.3.0 version anchor and standards-conformant version comparison.
- Inactive authenticated Nexus updates with preserved channel selection,
  progress and rollback through the existing versioned installer.
- Exact-tested candidate assembly and owner-gated immutable publication,
  promotion and role-separated all-channel freshness.

### Changed

- Native version no longer depends on reachable Git tags or shallow clone depth.
- Published and native versions now fold immutable first-parent merge titles.
  Non-publishing commits consume versions, and re-runs retain the same version.
  Development and preview tags use channel suffixes.

### Fixed

### Breaking

No settings migration is introduced by the versioning change.
Install a published bridge build from PR #140 before the first plain SemVer
build. Pre-bridge clients reject plain versions. Rolling back to an older
payload restores that format limit. Trust and highwater state must remain intact.

## [0.1.0-preview.2]

Historical public preview. See the existing GitHub release for its original notes.

## [0.1.0-preview.1]

Historical public preview. See the existing GitHub release for its original notes.
