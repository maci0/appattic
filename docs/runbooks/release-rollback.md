# Recovering a bad release

Recover a published bad build by shipping a corrected **new version**. Keep published tags fixed: an existing AppImage embeds a `.zsync` URL under its own `vX.Y.Z` tag. It does not discover a later tag automatically. Announce the replacement and give users its download link.

The tag-triggered `release` workflow currently publishes an x86_64 AppImage, `.zsync`, `.buildinfo`, and `.sbom.json`. The macOS release job is disabled. Manual workflow dispatch can build artifacts without publishing a tag release.

## Choose the recovery

- **Bad binary already distributed:** fix or revert the defect and release a new version. Explain the impact and any recovery steps in its notes. If the old binary must no longer be available, withdraw its release assets as described below.
- **Failed build before publication:** inspect the failure. Infrastructure failures may be retried at the same tag; source changes require a new version and tag.
- **Incorrect notes or metainfo:** correct the source and include the correction in the next release. A public release-body clarification can warn users sooner, but does not change metainfo embedded in existing binaries.

Deleting a tag does not make reusing its version safe. `scripts/check-version.sh` rejects a declared version when an existing matching tag points at another commit; removing the tag removes that local check's evidence, not the copies users already downloaded.

## Withdraw unsafe assets

First inspect the release and record its tag, commit, asset names, and failure:

```bash
gh auth status
gh release view vX.Y.Z
```

When withdrawal is necessary, delete the release while retaining its tag:

```bash
gh release delete vX.Y.Z --yes
```

Old asset/update links will no longer provide the withdrawn files. Deletion cannot recall downloaded copies. Publish a separate corrective release and communicate how to obtain it. Do not move the old tag or use `--cleanup-tag` to recycle a published version.

## Publish the correction

1. Fix or revert the defect and validate the result. A revert restores code behavior, not files already deleted or package state already changed on users' machines.
2. Update the version declaration and packaging copies together:
   - `Sources/AppAtticScan/Version.swift`.
   - The new highest-version `<release>` entry in `packaging/org.appattic.AppAttic.metainfo.xml`, with date and consumer-facing `<description>`.
   - `CFBundleShortVersionString` in `packaging/Info.plist`; also increment its positive integer `CFBundleVersion`.
   - The `.TH` version headers in `packaging/appattic.1` and `packaging/appattic-qt.1`.

   Run the version check and scan tests before tagging:

   ```bash
   bash scripts/check-version.sh
   bash scripts/test.sh
   ```

3. Commit the reviewed correction, then tag and push that commit:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

4. Watch the `release` workflow. Its `gate` checks the tag/version and runs the scan suite before either release job can start. The separate `linux` workflow is not a dependency of `release`; check it as well for broader platform coverage.
5. Verify the release body and all four assets, download the AppImage, and smoke-test the corrected behavior. The body comes from the matching AppStream release description via `scripts/release-notes.sh`. Announce the replacement download; users of the old tag do not automatically find it through the embedded update URL.

## Failed or partial publication

Inspect the actual release assets before retrying. `fail_on_unmatched_files: true` requires the expected files to exist locally, but publication is not an atomic transaction across uploads. A failed publish may leave a release or a subset of assets.

A retry at the same tag rebuilds from that commit. `SOURCE_DATE_EPOCH` and reproducibility checks reduce variation, but moving package repositories and host libraries mean the whole AppImage is not guaranteed byte-identical. Do not silently replace an already distributed image with different bytes under the same version. If that may have happened, use a new version and retain the old tag for traceability.

There is no automated rollback or recovery of user data. Release withdrawal and a corrective version are distribution actions; users may still need separate state or data recovery. See [state recovery](state-recovery.md).
