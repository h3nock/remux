# Task 8 final review: rename and move without contents

## Scope reviewed

- Commits `c818ccb`, `1f85860`, `e35b46f`, and `b0b0b27` against base
  `b42d234`.
- `FileProviderMutationCore.modify`, modify replay keys, coordinator
  cancellation acknowledgement, and the focused mutation-core tests.

## Result

Approved. No correctness findings in the reviewed Task 8 diff.

## Evidence

- The replay key includes both destination parent identifier and filename, so a
  second request with the same source version cannot replay a receipt for a
  different destination.
- The operation validates source/base version, parent type, child name,
  directory-cycle safety, and destination occupancy before the single remote
  rename. It refreshes the affected parent listings after that rename and
  commits relocation plus receipt atomically through the snapshot store.
- Snapshot relocation updates the source and every tracked descendant path
  while preserving their identities.
- Unsupported fields remain pending on both the initial modify result and a
  replayed receipt.
- Cancellation tests force cancellation at both sides of the irreversible
  rename boundary. The coordinator acknowledgement makes the gate ordering
  deterministic: pre-rename cancellation does not mutate or commit; after a
  successful rename, authoritative refresh and receipt commit complete.
- `git diff --check b42d234 b0b0b27` passed during this review.

The earlier focused test evidence remains 52 passing tests across
`FileProviderMutationCoreTests` and `FileProviderSnapshotStoreTests`. Live
SFTP and physical Files-app qualification remain separate gates.
