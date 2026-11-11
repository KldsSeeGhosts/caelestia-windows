## Change

Describe the problem and resulting Windows behavior. Link related issues.
Use a Conventional Commits PR title, such as `feat(scope): description` or
`fix: description`. Other recognised prefixes are `perf`, `refactor`, `docs`,
`test`, `build`, `ci`, `chore`, `style` and `revert`. Add `!` before `:` for a
breaking change and describe its migration and rollback compatibility.
The final title recorded in the merge commit determines the immutable version
bump. Labels do not. See [VERSIONING.md](../VERSIONING.md).

## Validation

List commands and observed results, shell/backend pins, Windows build, Qt
version and relevant monitors/DPI. Attach logs and screenshots here rather
than committing them, and identify untested cases.

## Compatibility and attribution

Describe desktop effects, opt-ins, configuration changes, recovery and known
limitations. Explain upstream file changes and material AI assistance.
AI-assisted and hand-written contributions are both welcome.

- [ ] Topic branch and `windows:` commit subjects.
- [ ] Relevant tests run and limitations recorded.
- [ ] If dependencies changed, reviewed backend commit and gitlink/manifest pins agree.
- [ ] New bundled components have source attribution and packaged license notices.
