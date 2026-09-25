# Releasing

Maintainer notes on cutting a release.

Releases are plain git tags (no `v` prefix: `1.0.2`, not `v1.0.2`) plus a GitHub
release whose title is the bare version and whose notes are that version's
CHANGELOG section body. The tag is lightweight and points at `main`'s tip at cut
time (for 1.0.2 that was the latest merge commit, not the changelog commit).

**CHANGELOG discipline**: every PR adds its entries to `## [Unreleased]` in
`CHANGELOG.md` as part of the PR itself. Cutting a release is then just stamping
that section with a version + title — never write release notes from scratch.

To cut a release, run from a clean, up-to-date `main` checkout:

```bash
scripts/release 1.0.4 "Short descriptive title"   # add --dry-run to preview
```

The script does, in order: preflight checks (clean tree on synced `main`, `gh`
authed, tag absent, non-empty `[Unreleased]`); stamps `CHANGELOG.md`
(`## [Unreleased]` → `## [X.Y.Z] — Title`, fresh empty `[Unreleased]` above);
commits as `Add X.Y.Z changelog entry` and pushes `main`; **waits for that
push's CI run and aborts before tagging if it fails**; pushes the lightweight
tag and runs `gh release create X.Y.Z --title X.Y.Z` with the section body
(minus `---` separators) as notes.

Title style matches the CHANGELOG headings — a terse summary of the dominant
changes, e.g. "Linux `SIGSEGV` workaround + `settle()` budget-cap enforcement".

If the script can't run (e.g. `main` is checked out in another worktree), the
same steps work remotely: merge a PR that stamps the CHANGELOG, then
`gh release create X.Y.Z --target <main-tip-sha> --title X.Y.Z --notes-file <notes>`
— `gh` creates the tag on the target commit.
