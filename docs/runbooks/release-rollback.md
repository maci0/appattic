# Recovering a bad release

A release here is a GitHub release holding the AppImage, its `.zsync`, its
`.buildinfo` and its `.sbom.json`, attached to a `v*` tag. The tag is the
trigger, so the release is whatever that tag built.

Two rules make a bad release awkward on purpose, and this page is what to do
about them:

- A version is immutable. `scripts/check-version.sh` fails when the declared
  version is a tag that points at another commit, so the same number cannot be
  shipped twice with different bytes.
- Nothing rewrites a published tag. There is no rollback step in the workflow,
  and there cannot be: the AppImage carries the update URL of its own tag, so a
  second build under that number would be an image that checks for an update to
  itself.

So recovering means moving the release to a new version, not replacing the old
one. The alternative, force-moving the tag, makes every AppImage already
downloaded point at a `.zsync` that no longer matches its own bytes.

## Decide which of the three it is

1. **The build is wrong, and no user has it yet.** The tag has not been
   announced. Delete the tag and the release below, fix the tree, bump the
   version, tag the new commit.
2. **The build is wrong and users have it.** Users who checked for updates get
   the new version the moment it is tagged. Ship it as a new version; do not
   try to retract the old one. Say in the new release's AppStream
   `<description>` what was wrong and what a caller has to change, because that
   text is the GitHub release body and the only place a user reads it.
3. **Only the metainfo or the note is wrong, and the binary is fine.** The
   release note is the newest `<release>` in
   `packaging/org.appattic.AppAttic.metainfo.xml`, and the note is the
   `<description>` under it. Edit that entry, bump the patch version, and tag
   again, so the published note and the shipped note are the same text.

## Withdrawing a release

Every step is a `gh` call; `gh auth status` first, and `gh release view vX.Y.Z`
to confirm which release the tag produced.

```bash
gh release delete vX.Y.Z --yes --cleanup-tag   # the release, its assets, and the tag
```

`--cleanup-tag` is what deletes the tag, and it is what makes the number
reusable: `scripts/check-version.sh` fails when the declared version already
carries a tag pointing at a different commit, so without it the same number
cannot be shipped again. (A tag pointing at the commit under the tree is that
normal release build, not a reuse.) If the tag is wanted for the history, delete
the release alone and move the tag yourself only when no user has downloaded
from it.

The release page keeps a `deleted` marker rather than a redirect, so a user
following an old download link lands on a 404. That is the correct outcome for
a build that must not be installed, and it is why step 2 above ships a new
version rather than deleting and stopping.

## Re-releasing

1. Fix the tree and land it. The tag is the trigger, so nothing releases until
   it is pushed.
2. Bump the version in all five declarations in one commit:
   `Sources/AppAtticScan/Version.swift`, the newest `<release>` in
   `packaging/org.appattic.AppAttic.metainfo.xml`, `packaging/Info.plist`, and
   the `.TH` and version headers in `packaging/appattic.1` and
   `packaging/appattic-qt.1`. `bash scripts/check-version.sh` fails when any of
   them disagree, and it runs in `scripts/lint.sh`, so a partial bump fails CI
   rather than a release.
3. Tag and push:

   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

   The tag is the trigger. `linux.yml` and `release.yml` both run on it, and
   `release.yml` does not depend on `linux.yml`: the two workflows are
   separate, so a green `linux.yml` alone does not stop the release. Its own
   `gate` job runs `scripts/check-version.sh --tag` and `scripts/test.sh`, and
   both release jobs declare `needs: [gate]`, so a red scan suite or a
   mistagged push stops the release before anything is published, and the
   suite runs once per tag rather than in every job that wanted it.
4. Watch the `release` workflow. A failure after `Publish AppImage` is not
   half-published: `fail_on_unmatched_files: true` means the release is only
   written once all four artifacts exist.

## What is deliberately not automated

- No automatic rollback. The only safe rollback is a new version, and a
  workflow cannot decide whether a build is bad; a human sees the failure.
- No delete-the-tag rollback. The immutability check and the embedded update
  URL both exist so a version means one set of bytes, and an automated way
  around that is a way to break it silently.
- No re-run of a failed publish against a rebuilt image. Re-run the workflow
  for the same tag: the artifacts are rebuilt from the same commit with
  `SOURCE_DATE_EPOCH` taken from it, and the cache key in `release.yml` names
  the toolchain and the sources, so the rebuild is the same bytes.
