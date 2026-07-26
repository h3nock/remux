# Task 9 report: safe regular-file content replacement

## Delivered

- `modify` now treats `.contents` as a supported field for regular files.
- It validates the current remote base version and destination before uploading,
  writes to a nonce-named sibling temporary path, checks cancellation before the
  final rename, and never truncates or deletes the destination first.
- The successful temporary-to-final rename is the remote commit boundary. A
  content rename or move removes its old source only after that boundary.
- Authoritative destination and parent listings are committed on a detached
  task with the identity relocation and receipt. Cancellation after the final
  rename therefore returns the committed result.
- If old-source removal fails after a cross-path content commit, the committed
  destination keeps its identity; the retained source receives a new identity
  and the snapshot transaction queues one working-set signal.
- Metadata-only rename and move behavior remains unchanged. No
  `NSExtensionFileProviderAppliesChangesAtomically` capability was added.

## Automated evidence

RED was observed with the new replacement test before implementation: no
remote mutation occurred and the old bytes remained. The test was then green
after content handling was added.

The exact focused command was run after the final change:

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/FileProviderMutationCoreTests \
  -only-testing:RemuxTests/RemuxFileProviderContractTests \
  -resultBundlePath /tmp/remux-task9-final.xcresult
```

It passed: 71 tests total, 0 failures. The result bundle is
`/tmp/remux-task9-final.xcresult`. `git diff --check` also passed.

Focused mutation tests cover temporary upload/final rename replacement,
content plus filename relocation, remote base-version conflict without upload,
directory-content rejection without upload, and post-commit old-source removal
failure retaining both paths with a new retained-source identity and a pending
working-set signal.

## Explicit live gates

- A disposable real SFTP/OpenSSH server must prove the server's strict rename
  replacement semantics: the final rename replaces an existing regular file
  without any delete-then-rename fallback, and a refused replacement leaves
  the old destination bytes intact.
- A physical iOS device must prove Files content editing, cancellation during
  upload and after final rename, progress delivery, and identity continuity for
  content-plus-rename and content-plus-cross-parent move.

## Round 1 review repair

### Root cause

The pre-commit content path caught cancellation after the upload and attempted
temporary-file removal from the cancelled mutation task. The production
mutation session correctly calls `Task.checkCancellation()` before removal, so
the discarded cleanup attempt never reached SFTP and leaked the temporary
sibling.

### Repair and coverage

- Added a narrow, awaited detached cleanup helper used only for a known
  temporary upload path. It preserves the original upload, rename, or
  cancellation error and leaves normal mutation cancellation checks intact.
- Checked the generated temporary path against the already-read destination
  parent listing before upload, so an existing nonce sibling is rejected rather
  than opened by the upload path.
- The cancellation-aware fake now checks cancellation before removal. The
  content cancellation test blocks after upload, waits until both outer and
  coordinator cancellation delivery are observed, releases the final rename,
  then proves the exact temporary removal, no rename, and unchanged destination.
- Added coverage for refused replacement rename preserving the old destination,
  upload failure cleanup, cross-parent content move ordering and parent
  refreshes, symlink-content rejection, and replay without another upload.

The exact focused command was rerun with
`/tmp/remux-task9-round1-final2.xcresult`. `xcresulttool` reports 77 passed,
0 failed, 0 skipped. `git diff --check` passed.
