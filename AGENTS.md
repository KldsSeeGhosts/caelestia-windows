# Agent guidelines for caelestia-windows

## Versioning

Caelestia uses [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- **MAJOR**: a breaking change for users or their data, such as a profile or
  config that no longer loads, a removed feature, or an incompatible installer
  or update path.
- **MINOR**: a new user-visible feature or a significant behaviour change.
- **PATCH**: a fix, polish, a performance improvement, or an internal change.

Before 1.0.0, a breaking change bumps MINOR instead of MAJOR. 1.0.0 is the
first release the owner declares stable.

Numbers never roll over at a threshold: 0.9.0 is followed by 0.10.0, and
1.2.9 by 1.2.10. Bumping MINOR resets PATCH to 0. Bumping MAJOR resets both
MINOR and PATCH.

### How a version is chosen

- Every merge to `main` that produces a build gets the next version, based on
  the most significant change it contains. Label each PR `breaking`,
  `feature` or `fix`. Docs-, CI- or test-only PRs that publish no build do
  not bump the version.
- A batch PR takes the highest bump among its contents.
- The development channel receives every published version. Preview and
  stable receive versions the owner promotes. Promotion does not renumber a
  build: the same version moves between channels.
- Version identities are immutable. A failed or re-run publication never
  reuses a published version.
- User interfaces show the plain version, such as `Caelestia 0.3.4`. Build
  metadata, such as the source revision or CI run, belongs in a collapsed
  details view, not in the version string.
