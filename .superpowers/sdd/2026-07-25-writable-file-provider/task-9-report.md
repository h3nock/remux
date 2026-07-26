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
