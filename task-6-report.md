# Task 6 report: writable File Provider contracts

## Delivered

- Added structured create, modify, and delete request value types. Modify fields
  are partitioned exactly into supported `contents`, `filename`, and
  `parentItemIdentifier` fields; every other requested field remains pending.
- Added a pure mutation validator for remote-version conflicts, exact and
  case-insensitive destination collisions, special-file and symlink policies,
  child names, missing parents, root mutation, directory contents, and
  directory move cycles.
- Projected writable capabilities exactly for roots, directories, and regular
  files. Symlinks and special files remain read-only.
- Moved the SDK item adapter into shared provider source and removed the
  read-only mutation policy and extension-only adapter.
- Added collision, rejected-deletion, directory-not-empty,
  cannot-synchronize, and write-permission errors. Collision and rejected
  deletion use the public FileProvider constructors with the affected item.

## Automated evidence

- RED: the focused suite initially failed to compile because the newly tested
  `FileProviderMutationValidator`, field partition, shared SDK item, writable
  capability behavior, and mapper constructors did not exist.
- GREEN: the focused suite passed 65 tests with no failures:

  ```sh
  xcodebuild test -quiet -parallel-testing-enabled NO \
    -derivedDataPath .build/task-6-green \
    -project Remux.xcodeproj -scheme Remux \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:RemuxTests/FileProviderMutationValidatorTests \
    -only-testing:RemuxTests/FileProviderRemoteItemTests \
    -only-testing:RemuxTests/FileProviderErrorMapperTests \
    -only-testing:RemuxTests/RemuxFileProviderContractTests
  ```

- `git diff --check` passed.
- No Swift source references `FileProviderReadOnlyMutationPolicy` or
  `RemuxFileProviderItem`.

## Deferred gates

- There is no live SFTP mutation implementation in Task 6. Remote create,
  modify, rename, move, and delete execution are intentionally deferred to
  later plan tasks.
- The File Provider extension’s device behavior has not been validated on a
  physical device or against a disposable writable SSH/SFTP host. Simulator
  tests prove these contracts only; they do not qualify server-side mutation
  behavior or the extension’s eventual writable configuration.
