# Task 10: File and empty-directory deletion

## Delivered

- Added `FileProviderMutationCore.delete(request:)` with serialized replay,
  identity, remote-path, type, and base-version validation.
- Deletes regular files with `removeFile` and directories only after a fresh,
  empty listing with `removeEmptyDirectory`. The recursive option does not
  enable recursive deletion.
- Treats an already absent remote item as an idempotent deletion, refreshes the
  authoritative parent, removes the tracked identity (including descendants),
  and records a deleted receipt in the same snapshot save.
- Runs post-remote-commit snapshot work in the detached committed-mutation
  boundary, so cancellation after `removeFile` or `rmdir` cannot discard the
  snapshot update or receipt.

`FileProviderSnapshotStore` already had the needed deleted-identity subtree
pruning. Task 10 adds a direct regression test for that behavior rather than
duplicating or changing the existing implementation.

## Automated evidence

RED was observed with the exact focused command before implementation: the
new tests failed because `FileProviderMutationCore.delete` and
`FileProviderDeleteMutationError` did not exist.

GREEN command:

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/FileProviderSnapshotStoreTests
```

Result: `** TEST SUCCEEDED **`; 75 tests executed with 0 failures. Result
bundle: `/Users/jesse/Library/Developer/Xcode/DerivedData/Remux-baapfdiwnnvmtnfolpbdblblyvtw/Logs/Test/Test-Remux-2026.07.25_18-13-18--0700.xcresult`.

Coverage added for regular files, empty and non-empty directories, recursive
option rejection, already-absent deletion, stale versions, root/symlink/special
rejection, permission mapping, receipt replay, cancellation after remote
commit, and descendant pruning.

## Deferred gates

- Live SFTP host: verify server-specific `rmdir` error behavior and permission
  mapping against a disposable account. The unit fixture proves the core
  contract, not a real server's implementation.
- Device Files integration: exercise iOS File Provider delete callbacks and
  confirm their user-visible error presentation. The focused simulator tests do
  not replace this gate.
