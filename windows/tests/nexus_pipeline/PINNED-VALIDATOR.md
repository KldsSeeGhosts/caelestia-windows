# Offline validator fixture

`pinned_candidate_contract.py` is an unmodified copy of
`.github/scripts/candidate_contract.py` from
https://github.com/KldsSeeGhosts/caelestia-quickshell-windows at
ae98287c8cd96db4ea4642cc91a1cd9ba7c32a1f.

SHA256: 220ab389252a15b8f4d9db25076aa01a927b3b07c62f3a07a76d1431d560f275.

It belongs to the same GPL-licensed Caelestia Windows source family. Preserve
the upstream bytes. This offline test fixture is never used as a production
trust override: production extracts from the pinned producer commit and checks
the same unchanged digest before import. Unit tests need no network/submodule
checkout and validate real complete synthetic receipts through this exact code.
