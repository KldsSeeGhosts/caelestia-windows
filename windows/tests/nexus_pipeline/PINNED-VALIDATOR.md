# Offline validator fixture

`pinned_candidate_contract.py` is an unmodified copy of
`.github/scripts/candidate_contract.py` from
https://github.com/KldsSeeGhosts/caelestia-quickshell-windows at
bd5c68196edbdaad23db8f28ca64214d075711b4.

SHA256: e7e890428a49812208866349a00482cf0cddbca6ebbaf71cb7a06a5c3284b5a0.

It belongs to the same GPL-licensed Caelestia Windows source family. Preserve
the upstream bytes. This offline test fixture is never used as a production
trust override: production extracts from the pinned producer commit and checks
the same unchanged digest before import. Unit tests need no network/submodule
checkout and validate real complete synthetic receipts through this exact code.
