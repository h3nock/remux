# Task 14 coordinator ordering race-fix review

Reviewed commit range `5396170a1a54464796464a7b80c7441ba5bcad5a..43c75cec128031ab43ce1414e415fbb01c9614d7`.

Verdict: approved.

The production coordinator at the final commit exactly matches the pre-hook baseline
(`0062932`) for `RemuxApp/Sources/FileProvider/FileProviderDomainOperationCoordinator.swift`.
The range removes the temporary DEBUG-only test observation hook introduced by the
first race-fix attempt; it does not leave a production behavior change.

The regression now releases the first refresh and waits for the mutation operation's
existing blocking gate to be entered before submitting the second refresh. That is a
behavioral synchronization point: the queued mutation has become active, so the
second same-directory refresh cannot coalesce with the first one. The changed test
contains no sleep, yield, or scheduler-timing assertion. (A separate cancellation
test retains its pre-existing cancellable 60-second sleep.)

Validation:

- `git diff --quiet 0062932 43c75ce -- RemuxApp/Sources/FileProvider/FileProviderDomainOperationCoordinator.swift` exited 0.
- `git diff --check 5396170 43c75ce` passed.
- The isolated `FileProviderDomainOperationCoordinatorTests` target passed three
  consecutive `xcodebuild test` runs: 6 tests, 0 failures each run.

The commit's RED/GREEN rationale is sound: the old ordering could submit the second
refresh before the queued mutation became active, allowing coalescing with the first
refresh; the new gate makes that interleaving impossible while preserving the intended
FIFO assertion.
