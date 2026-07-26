# Task 7 report: File Provider create mutation core

## Commits

- Base: `b95380023a49880bafceb6a0c05e20c61e3896ca`
- Implementation: `8da04dc7878a30dc5f5f9ebfb53a45ad0392111f` (`Create files and directories through File Provider`)

## RED evidence

The initial focused build was intentionally RED because
`FileProviderMutationCore` and `FileProviderMutationResult` did not exist.
After project regeneration, the test fixture also exposed Swift 6 actor
isolation errors; those were test-fixture compilation errors, not production
behavior.

## GREEN evidence

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-task7-diagnose \
  -resultBundlePath /tmp/remux-task7-diagnose-green.xcresult \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests
```

The result bundle reports 11 passed, 0 failed.

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-task7-diagnose \
  -resultBundlePath /tmp/remux-task7-contracts.xcresult \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

The result bundle reports 46 passed, 0 failed. `git diff --check` passed.

## Self-review

- Create runs through the domain mutation coordinator, performs fresh parent
  listing collision validation, and never constructs a shell command.
- Regular files upload to a UUID-only temporary sibling then rename; only that
  exact temporary path is best-effort removed before a successful rename.
- Directories use strict mkdir. Symlink and special-file creation is rejected
  before remote mutation access.
- Final remote item/listing, identity reservation, snapshot, and replay receipt
  persist in a detached committed phase so post-rename cancellation cannot
  discard authoritative state.
- The extension core bridges mutation progress to `Progress` and returns the
  structured mutation result. Modify and delete execution remain unimplemented.

## Explicit deferred gates

- No disposable writable SSH/SFTP host qualification was run.
- No physical-device Files/File Provider qualification was run.
- The extension Info.plist still has its existing read-only installation gate;
  Task 7 does not change installed-provider configuration.

## Review round 1

Root causes found in fresh review:

- Extension-core create allocated a second operation coordinator while
  enumerators used setup's coordinator, permitting refresh and create to race.
- The generic request controller correctly discarded ordinary results after
  cancellation, but incorrectly discarded a create result whose remote rename
  and authoritative persistence had already committed.
- Collision validation discarded the existing remote item before the extension
  could create the required File Provider collision NSError.

Fixes inject setup's coordinator into extension core, add an opt-in committed
result cancellation policy used only by create, and carry structured collision
data through the bridge. The actor-backed mutable fake now supports removal
gates and directory descendant rename behavior.

Verification:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-task7-round1 \
  -resultBundlePath /tmp/remux-task7-round1-final.xcresult \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Result: 50 passed, 0 failed. `git diff --check` passed.

## Review round 2

Replaced the coordinator-only race with a real extension-core create and
enumerator refresh using the same injected coordinator. The refresh listing is
gated before `createItem`; final snapshots retain the created item, proving the
create waits behind the refresh instead of being published and then overwritten.

Added deterministic cleanup-gate coverage for rename failure, including exact
temporary-path removal and no destination residue. Added direct mutable-fake
directory rename coverage for descendant path and content relocation.

Focused verification result bundle:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-task7-round2 \
  -resultBundlePath /tmp/remux-task7-round2.xcresult \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

Result: 52 passed, 0 failed. `git diff --check` passed.

## Review round 3

The mutable remote listing gate now captures directory entries before blocking.
This makes the refresh a genuine stale-list race: a separate-coordinator control
creates `report.txt` while the captured empty refresh waits, then overwrites the
snapshot with that empty list. The shared extension/enumerator coordinator test
queues create behind the refresh and retains `report.txt` in the final snapshot.

Focused result bundle `/tmp/remux-task7-round3-fixed.xcresult`: 53 passed, 0
failed. `git diff --check` passed.
