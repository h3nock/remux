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

## Round 1 replay and fixture repair

### Root causes

- The modify replay key contained only the original item identity, base version,
  and changed field mask. Two distinct destination requests with the same base
  version therefore shared a receipt key and could replay the first move.
- Generic item-receipt replay always returned no pending fields, which lost
  unsupported metadata fields from a mixed modify request.
- The mutation fixture reused one identity UUID for every snapshot allocation
  and did not consistently record nested parent snapshots. Its cross-parent
  list assertion also omitted post-rename parent refreshes.

### Repair

- Extend modify replay keys with the requested parent identifier and filename.
- Reconstruct modify pending fields from the receipt key's changed field mask;
  create receipt replay remains unchanged.
- Use a locked deterministic identity sequence, record the nested parent during
  fixture setup, and assert two pre-rename plus two post-rename listings for a
  cross-parent move.
- Add cancellation boundaries: cancellation before the blocked rename performs
  no mutation or receipt commit; cancellation after a successful rename waits
  for authoritative refresh and commits relocation.

### Exact focused green command and result

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Result bundle inspected with `xcrun xcresulttool get test-results summary`:
`result: Passed`, `passedTests: 52`, `failedTests: 0`, `skippedTests: 0`
(31 mutation-core and 21 snapshot tests). `git diff --check` passed.

## Round 2 cancellation evidence

The cancellation tests now wrap the outer `core.modify` task in
`withTaskCancellationHandler` and wait for a cancellation-delivery latch after
`task.cancel()` before releasing either remote gate. This proves cancellation
has reached the outer operation at the boundary under test.

- Before rename: cancellation delivery is observed before the blocked rename
  is released; no rename and no modify receipt are asserted.
- After rename: cancellation delivery is observed before the authoritative item
  read is released; the task succeeds with the exact modify item receipt and
  stable relocated source and descendant paths.

The exact focused command above was rerun. Its inspected result bundle reports
`result: Passed`, `passedTests: 52`, `failedTests: 0`, `skippedTests: 0`.
`git diff --check` passed. Production behavior was unchanged.
