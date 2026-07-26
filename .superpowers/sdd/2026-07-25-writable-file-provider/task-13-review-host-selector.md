# Task 13 host-selector review

Commit reviewed: `8efc585` (`Select explicit host for writable SFTP qualification`)

Verdict: approved.

## Scope and behavior

- `REMUX_WRITABLE_SFTP_SERVER_HOST` selects only a saved server whose `host` exactly equals the requested value.
- A requested host with no saved server returns no profile; the integration test skips and does not fall back to the latest profile.
- The workspace is obtained through `ConnectionLibrarySnapshot.workspaces(for:)`, so it belongs to the selected server and retains the snapshot's deterministic latest-workspace ordering.
- With no requested host, the pre-existing `latestProfile` behavior remains unchanged.
- The selector is test-only and is reached only after the existing opt-in integration gate and dedicated-root validation; it introduces no production mutation path.

## Evidence

Ran:

```sh
xcodebuild test -project Remux.xcodeproj -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSFTPReadOnlyClientTests
```

Result: 19 tests passed, 1 expected opt-in integration test skipped, 0 failures. No live server was contacted.
