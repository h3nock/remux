# Task 8 report: rename and move without contents

## Delivered

- Added `FileProviderMutationCore.modify(request:progress:)` for metadata-only
  rename and reparent operations.
- Replays completed modify receipts before issuing another SFTP mutation.
- Reads current source and parent metadata, validates the remote base version,
  source/destination types, names, cycles, and case-insensitive destination
  collisions before one strict SFTP rename.
- Refreshes the old and new parent listings after the rename, commits the
  authoritative moved item and receipt, and uses the existing relocation
  transaction to retain source and known-descendant identities.
- Leaves content replacement pending; it does not use delete-then-rename or
  any in-place content update.

## Automated evidence

RED was observed before implementation: the focused command failed because
`FileProviderMutationCore.modify` and its modify conflict surface were absent.

GREEN command passed after implementation:

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

The focused suites cover file rename, cross-parent move, known directory
descendant relocation, cycle and collision rejection, remote base-version
conflict, root and symlink rejection, receipt replay, exact pending fields,
and the snapshot relocation transaction. `git diff --check` also passed.

## Deferred gates

- A disposable real SFTP/OpenSSH server must still prove the strict single
  rename behavior and server-specific collision semantics.
- A physical iOS device must still prove Files integration, including
  File Provider conflict/collision presentation and identity continuity across
  rename and move.
- Delete remains intentionally unimplemented and is outside Task 8.
