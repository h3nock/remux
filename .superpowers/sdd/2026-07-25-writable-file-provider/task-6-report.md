# Task 6 report: structured writable File Provider contracts

## Commits

- Base: `e8ec5cff2e171cce346bb8934bbee5a464731dee`
- Implementation: `e7280e0` (`Define writable File Provider contracts`)

## Changed files

- `RemuxApp/Sources/FileProvider/FileProviderMutationRequest.swift`
  - Added create, modify, and delete request values plus the exact supported
    modified-field partition: `contents`, `filename`, and
    `parentItemIdentifier`.
- `RemuxApp/Sources/FileProvider/FileProviderMutationValidator.swift`
  - Added pure validation for version conflicts, exact and case-insensitive
    destination occupancy, special files, symlinks, child names, missing
    parents, root mutation, directory contents, and directory move cycles.
- `RemuxApp/Sources/FileProvider/FileProviderItemProjection.swift`
  - Projects the writable root, directory, and regular-file capability policy;
    symlinks and special files retain read-only capabilities.
- `RemuxApp/Sources/FileProvider/FileProviderSDKItem.swift`
  - Moved the `NSFileProviderItem` adapter into shared provider source.
- `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`
  - Added collision, rejected-deletion, directory-not-empty,
    cannot-synchronize, and write-permission errors. The first two use the
    public FileProvider error constructors with the affected SDK item.
- `RemuxApp/Sources/FileProvider/FileProviderReadOnlyMutationPolicy.swift`
  - Removed; remaining temporary mutation rejection paths use the precise
    mapper write-permission error directly.
- `RemuxApp/Sources/FileProvider/FileProviderReplicatedExtensionCore.swift`,
  `RemuxFileProvider/Sources/RemuxFileProviderExtension.swift`, and
  `RemuxFileProvider/Sources/RemuxFileProviderEnumerator.swift`
  - Updated shared SDK item and error-mapper references.
- `RemuxFileProvider/Sources/RemuxFileProviderItem.swift`
  - Removed after relocation to shared source.
- `RemuxAppTests/FileProviderMutationValidatorTests.swift`,
  `RemuxAppTests/FileProviderRemoteItemTests.swift`,
  `RemuxAppTests/FileProviderErrorMapperTests.swift`, and
  `RemuxAppTests/RemuxFileProviderContractTests.swift`
  - Added validator, capability, field partition, error-payload, and updated
    writable capability contract coverage.
- `Remux.xcodeproj/project.pbxproj`
  - Regenerated with XcodeGen for the moved and added sources.

## TDD evidence

RED command:

```sh
xcodebuild test -derivedDataPath .build/task-6-red \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationValidatorTests \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

The first shared-DerivedData invocation was blocked by an unrelated build
database lock. The isolated rerun reached the intended compile-time RED: the
validator, field partition, shared SDK item, writable error constructors, and
writable capability behavior did not yet exist.

GREEN command:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-task6-final.OdtTTv \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationValidatorTests \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Result: 65 passed, 0 failed. `git diff --check` completed with no output.

## Self-review

- Capability projection is exact by item type: root directories cannot be
  renamed, reparented, or deleted; non-root directories and regular files have
  only the policy-approved writable capabilities; symlinks and special files
  remain read-only.
- Field support is a literal intersection with the three currently implemented
  fields; metadata-only changes remain pending rather than being silently
  accepted as supported.
- The validator performs no network I/O. Its collision and cycle comparisons
  are deterministic, and its type policy rejects every symlink mutation and
  special-file mutation.
- Collision and rejected-deletion mapping is tested for the carried SDK item,
  not merely the error code.
- No Swift source references the removed read-only mutation policy or the old
  extension-only item adapter.

## Explicit deferred gates

- `RemuxFileProvider/Info.plist` still declares
  `NSExtensionFileProviderReadOnly: true`. Changing the extension's installed
  writable configuration is deliberately outside Task 6 and remains a later
  plan gate.
- Task 6 introduces contracts only. Remote SFTP create, modify, move, rename,
  and delete execution remains deferred to the mutation-core tasks.
- No disposable writable SSH/SFTP host qualification was run.
- No physical-device Files/File Provider qualification was run. The focused
  simulator suite is not evidence of device behavior or live server mutation
  correctness.
