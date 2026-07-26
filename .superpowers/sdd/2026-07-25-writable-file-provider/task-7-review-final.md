# Task 7 final review: file and directory creation

## Scope reviewed

- Task 7 brief and report.
- Commits `8da04dc`, `1f794a3`, `7b89f78`, and `b42d234`, from base
  `b953800`.
- The mutation core, extension bridge, shared operation-coordinator wiring,
  actor-backed mutable remote fixture, and focused regression tests.

## Findings

No critical, important, or minor findings.

## Verified contract

- Create validates the authoritative parent and fresh listing before reserving
  an identity or mutating remotely.  Regular files use a UUID-only temporary
  sibling, preflight that sibling for occupancy, then upload and strictly
  rename; directories use strict `mkdir`.
- Pre-rename upload, rename, and cancellation failures remove only the exact
  newly-created temporary sibling.  A fixed-nonce sentinel regression proves
  a pre-existing temporary sibling is neither overwritten nor removed.
- The committed phase refreshes authoritative metadata, updates the snapshot,
  reserves the identity, and records the replay receipt after a final rename or
  successful `mkdir`.  The extension bridge deliberately preserves that result
  after cancellation, while cancellation before the final rename remains an
  error.
- Creation and enumeration receive the same domain coordinator in the
  production setup.  The paired separate-coordinator control demonstrates the
  stale-refresh failure mode; the shared-coordinator assertion retains the new
  item in the final snapshot.
- Collision errors retain the existing SDK item, and symbolic-link creation is
  translated to `cannotSynchronize` at the extension boundary.

## Verification

Passed locally:

```sh
xcodebuild test -quiet -parallel-testing-enabled NO \
  -derivedDataPath /tmp/remux-review-task7-b \
  -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests
```

`git diff --check b953800 b42d234` also passed.

## Verdict

**Specification verdict: approved.** The complete Task 7 range satisfies the
create, replay, cleanup, cancellation, and shared-coordinator contracts.

**Quality verdict: approved.** The tests exercise real structured mutation
behavior and deterministic concurrency boundaries.  Live SFTP and physical
Files-app qualification remain intentionally outside this task.
