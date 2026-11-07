# Versioning

Versions are MAJOR.MINOR.PATCH, not decimals. `windows/release/version.json`
is the reviewed native version source, currently 0.2.0. Existing
0.1.0-preview.1 and 0.1.0-preview.2 history is preserved.

Before 1.0, a minor may break settings, bindings or installation layout.
Every break must have a changelog migration and a rollback compatibility note.
Patches must not break compatibility. After 1.0, breaking changes require a
major, compatible features a minor, and fixes a patch. Only the owner declares
1.0, after polished, dependable operation has been demonstrated.

General parsing and precedence follow SemVer 2.0.0, including build metadata
(ignored for precedence), arbitrary-length numeric identifiers, and ordinal
case-sensitive prerelease ordering. Published versions deliberately use a
narrower grammar without build metadata.

Development identity is `CORE-dev.EPOCH.RUN.ATTEMPT`. All three identifiers
are positive decimal strings, not bounded integers. EPOCH is a reviewed
`developmentEpoch` in version.json. Increment it before renaming/replacing the
producer workflow or resetting its run counter. RUN is that workflow's
run_number; ATTEMPT is run_attempt. A rerun cannot overwrite an earlier
attempt's immutable bytes. Source ancestry and the channel highwater must also
advance; an overlapping older build must never supersede a newer publication.
Pointer sequence is separate from build identity.

Preview and stable are deliberate signed aliases of immutable development
artifacts. Installed build identity must always remain visible separately from
the alias and selected update channel. Never rewrite compiled or manifest bytes
to promote them. Stable aliases require a core of at least 1.0.0: promoting a
0.2.0 artifact to 1.0.0 is forbidden. The reviewed core bump must first produce
and validate a 1.0.0-dev artifact. Stable clients use only stable metadata, not
the development pointer. A channel switch cannot authorize a network downgrade.

Native numeric version is CORE only, with components 0..65535 for future
Windows VERSIONINFO compatibility. A source revision is provenance, not a
version. Release IDs, directory IDs and JSON schema versions are not app
versions. Local/unpublished payloads must not be advertised as channel releases.
