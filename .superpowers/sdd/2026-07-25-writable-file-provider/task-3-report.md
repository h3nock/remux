# Task 3 report: strict SFTP write primitives

Base commit: `962c8b8f15c01b0831668a57e9ba85474cb0701c`

## Changed files

- `RemuxApp/Sources/SSH/RemuxSFTPClient.swift`
  - Added the File Provider write-client protocol and typed `permissionDenied`
    and `unsupportedMutation` errors.
- `RemuxApp/Sources/SSH/RemuxCitadelSFTPClient.swift`
  - Added strict create, rename, file remove, and empty-directory remove
    adapters; wired directory removal to Citadel `rmdir(at:)`; retained the
    terminal upload protocol and shares the upload implementation.
  - Provider mutations do not perform existence recovery, delete-then-rename,
    or cancellation cleanup mutations.
- `RemuxApp/Sources/FileProvider/FileProviderErrorMapper.swift`
  - Maps typed write permission denial to the existing Cocoa write-permission
    error. Unsupported mutations remain sanitized.
- `RemuxAppTests/RemuxSFTPReadOnlyClientTests.swift`
  - Added exact SFTP mutation-sequence, permission/failure normalization, and
    cancelled-upload close/no-follow-up-mutation coverage.

## Normalization decisions

- Citadel `SFTPError.errorStatus(.permissionDenied)` maps to
  `RemuxSFTPClientError.permissionDenied` for write operations only.
- Citadel `SFTPError.errorStatus(.failure)` maps to
  `RemuxSFTPClientError.unsupportedMutation` for write operations only.
- Other Citadel statuses remain unchanged. Read error normalization was not
  modified.
- `permissionDenied` maps to `NSFileWriteNoPermissionError`; unsupported
  mutation remains sanitized pending Task 6 operation-specific errors.

## Tests and commands

RED (before implementation):

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Result: expected compile failures for the absent strict write methods and new
typed errors.

GREEN/final verification (same command):

Result: `Executed 12 tests, with 0 failures`; `** TEST SUCCEEDED **`.

Also ran `git diff --check` successfully.

## Self-review

- Strict directory creation calls only `mkdir` and does not convert an
  existing path into success.
- Strict file and directory removal map directly to `remove` and `rmdir`.
- Rename performs exactly one Citadel rename; there is no delete fallback.
- Cancellation closes the uploaded handle and has no later rename/remove
  action.
- The terminal attachment transfer protocol remains present and reuses the
  single upload implementation.

## Concerns

None for the scoped automated work. No live SFTP host session was requested or
run. Citadel keeps `SFTPMessage.Status` construction internal, so the focused
unit test verifies the extracted public `SFTPStatusCode` mapping while the
production boundary matches Citadel's `SFTPError.errorStatus` wrapper.

---

## Fix round 1: collision and mapper coverage

### Root cause and correction

The shared Citadel write seam hard-coded `.write`, `.create`, and `.truncate`,
which silently truncated an existing remote path before the File Provider could
report a collision. The seam now accepts explicit `SFTPOpenFileFlags`, and the
single shared upload implementation requests `.write`, `.create`, and
`.forceCreate` (without `.truncate`). A remote destination collision therefore
fails before any upload write.

The terminal attachment transfer remains on the same upload protocol and
implementation. Its temporary remote path includes the job's workspace UUID
and transfer UUID, so normal terminal uploads retain unique temporary paths.

### Added coverage

- A strict-upload collision test configures an existing remote path and proves
  the exclusive-create request fails without writing bytes.
- Existing exact-operation and cancellation tests now assert the explicit
  exclusive-create flags.
- Mapper tests prove `permissionDenied` becomes `NSFileWriteNoPermissionError`
  and `unsupportedMutation` remains sanitized.

Citadel's `SFTPMessage.Status` initializer is internal to the pinned package,
so a fake connection cannot construct `SFTPError.errorStatus` without unsafe
test machinery. The existing public `SFTPStatusCode` normalization test covers
the status mapping; production still performs that mapping only after matching
Citadel's `SFTPError.errorStatus` boundary.

### Commands and output

RED:

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests \
  -only-testing:RemuxTests/FileProviderErrorMapperTests
```

Result: expected compilation failure because the test seam required write flags
that the production connection protocol did not yet expose.

GREEN/final verification (same command): `Executed 21 tests, with 0 failures`;
`** TEST SUCCEEDED **`.

`git diff --check` also completed successfully.
