# Task 3 final review: strict SFTP write primitives

Reviewed implementation range: `962c8b8..9ac9ec1`.

## Verdict

**Spec compliance: approved.**

**Code quality: approved.**

The File Provider client exposes the requested strict mutation surface and the
Citadel adapter maps each operation directly to its corresponding SFTP request.
Creation uses `SSH_FXF_CREAT | SSH_FXF_EXCL` (`.create | .forceCreate`), so an
existing temporary destination fails before any bytes are written.  The adapter
does not use truncation, existence recovery, delete-then-rename, or recursive
directory removal.  `rmdir` is used only by the empty-directory method.

Write-only error normalization handles both Citadel representations observed at
the boundary: `SFTPMessage.Status` and `SFTPError.errorStatus`.  It leaves
read-error behavior unchanged, maps permission denial to the existing Cocoa
write-permission error, and sanitizes unsupported mutations as specified.

## Verification performed

```sh
git diff --check 962c8b8..9ac9ec1
xcodebuild test -quiet -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Both commands succeeded.  The test target covers exact write requests,
exclusive-create collision behavior, upload cancellation/remote-handle close,
and the error-mapper contracts.

## Findings

None.
