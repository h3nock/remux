# Task 1 review: stable opaque identities end to end

Reviewed the exact Task 1 package `8674ac6..a8ea8cd` against the task brief,
implementer report, and current production/tests in the worktree. The current
branch contains later writable-provider commits; those were checked only where
they touch the Task 1 snapshot/identity contracts. No production files were
changed during this review.

## Spec compliance

**FAIL.** The identity format, v2 storage, persisted parent identities, and
identity-based item/content lookup are present, but fresh-domain root
enumeration is broken by synchronous root lookup.

## Strengths

- `FileProviderItemIdentifierCodec` emits `i:<UUID>` identifiers and no longer
  derives identifiers from paths (`RemuxApp/Sources/FileProvider/FileProviderRemotePath.swift:59-86`).
- `FileProviderIdentifiedItem` persists both the opaque item identity and the
  approved opaque `parentIdentity` (`RemuxApp/Sources/FileProvider/FileProviderItemIdentity.swift:13-20`).
- Snapshot state is isolated in `snapshot-generations-v2.json`; the production
  snapshot store has no read/write path for the unshipped legacy filename
  (`RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift:16-43`).
- Deltas compare remote metadata while reporting persisted opaque identifiers,
  and nested projections use the stored parent identity
  (`RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift:624-655`,
  `RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift:16-29`).
- Unknown persisted identities map to File Provider's requested `noSuchItem`
  error with the requested identifier payload
  (`RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift:45-59`).

## Findings

### Critical

None.

### Important

#### I1. A fresh domain cannot synchronously resolve the root container

`FileProviderSnapshotStore.pathSynchronously(for:)` checks that the v2 state
file exists before calling the helper that correctly handles `.rootContainer`
(`RemuxApp/Sources/FileProvider/FileProviderSnapshotStore.swift:282-291`,
`658-670`). On the first File Provider callback for a new domain, no snapshot
file exists yet; `RemuxFileProviderExtension.enumerator(for:)` calls this method
before the asynchronous root enumeration can create the first snapshot
(`RemuxFileProvider/Sources/RemuxFileProviderExtension.swift:203-218`). The
call therefore throws `itemIdentityNotFound`, maps to `noSuchItem`, and prevents
the provider from ever enumerating its root on a fresh install. This violates
the brief's requirement that the root identifier resolve to `.root` and its
synchronous enumerator contract. Special-case `.rootContainer` before the file
existence check (or decode an empty state) and add a fresh-store root lookup /
enumerator regression.

### Minor

#### M1. The legacy-file test does not prove the old file is untouched

`testUnshippedLegacySnapshotFileIsIgnored` creates
`snapshot-generations.json` but only asserts that the v2 file exists
(`RemuxAppTests/FileProviderSnapshotStoreTests.swift:364-382`). A regression
that deletes or rewrites the old file would still pass. Capture the original
bytes and assert they remain unchanged after recording the v2 snapshot.

## Task quality

**FAIL.** The implementation has a clean identity/snapshot separation and
meaningful structured coverage, but the missing fresh-domain root path is an
end-to-end startup blocker, and the tests do not exercise that required path.
