# Task 6 final review: writable File Provider contracts

Reviewed `e8ec5cf..b953800` against the Task 6 brief, Task 6 report, the
current mutation-core callers, and the focused contract tests.

## Findings

None.

## Verified behavior

- The create, modify, and delete request values preserve the SDK values needed
  by later mutation callbacks. The field partition has the literal supported
  set (`contents`, `filename`, and `parentItemIdentifier`) and retains all
  other fields as pending.
- Capability projection is exact for root directories, non-root directories,
  regular files, symlinks, and special files. Root cannot be renamed,
  reparented, or deleted; symlinks and special files remain read-only.
- The pure validator rejects every planned unsupported mutation before remote
  work: special files, symlinks, invalid child names, missing parents, root
  mutation, directory contents, occupied destinations (including
  case-insensitive matches), and a directory move into itself or a descendant.
  It compares the requested and current File Provider versions without
  modifying either item.
- Writable error constructors use the File Provider APIs that carry the
  conflicting or updated SDK item. Directory-not-empty and
  cannot-synchronize use their designated File Provider codes, while SFTP
  permission denial maps to the Cocoa write-permission error.
- `FileProviderSDKItem` is now shared provider code and the obsolete
  read-only policy and extension-local adapter are removed from active Swift
  sources. Current mutation-core call sites use the Task 6 contracts without
  widening the policy.

## Verification

Passed locally:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-task6-review \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationValidatorTests \
  -only-testing:RemuxTests/FileProviderRemoteItemTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests

git diff --check e8ec5cf..b953800
```

The selected test command exited 0. The build emitted two pre-existing
`NIOSSHHandler` Sendable-availability warnings from
`RemuxSSHRootService.swift`; it emitted no test failures. `git diff --check`
completed with no output.

## Verdict

**Spec verdict: pass.** Task 6 supplies the specified structured contracts,
capability policy, pure validation, and writable error mapping with focused
coverage.

**Quality verdict: pass.** The logic is narrowly scoped, policy is explicit,
and the affected contract suite is green.
