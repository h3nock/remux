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
